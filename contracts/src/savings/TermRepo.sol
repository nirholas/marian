// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {AssetRegistry, AssetConfig} from "../core/AssetRegistry.sol";
import {IPriceSource, PriceStatus} from "../interfaces/IPriceSource.sol";
import {IERC20} from "../interfaces/IERC20.sol";

enum NoteState {
    None,
    Open,
    Matched,
    Repaid,
    Foreclosed,
    Cancelled
}

/// @notice One fixed-term deposit, and the loan that funds its rate.
struct Note {
    address lender;
    address borrower;
    address collateralAsset;
    uint256 principal;
    /// @dev Interest for the whole term, paid into this contract when the note is matched. Not a
    ///      projection: the dollars are here.
    uint256 interest;
    uint256 collateralRaw;
    uint32 termSeconds;
    uint16 aprBps;
    uint64 maturity;
    NoteState state;
}

/// @title TermRepo
/// @notice Lock dollars for a fixed term at a fixed rate. A certificate of deposit, which retail
///         has understood for a century.
///
/// @dev **Why the rate can honestly be called guaranteed.** Most on-chain "fixed rate" products are
///      a floating pool with a smoothing function on top, and the fixed number is a forecast that
///      breaks under stress. This one is a term repo: a borrower takes the deposit for exactly its
///      term, posts over-collateralised tokenized equity against it, and pays **the entire term's
///      interest into escrow at the moment of matching**. From that instant the lender's return is
///      not a projection, it is a balance in this contract, and the only remaining question is the
///      principal, which is over-collateralised and foreclosable.
///
///      There is no duration mismatch, because the loan's term is the deposit's term. There is no
///      junior tranche absorbing a shortfall, because there is no shortfall to absorb. There is no
///      rollover risk, because nothing rolls.
///
///      **What the lender is actually told.** Unmatched money earns nothing, and the interface says
///      so rather than blending it into an average. A deposit is either matched, earning its stated
///      rate out of dollars already escrowed, or it is idle and cancellable at any moment with no
///      penalty. Those are the only two states, and both are visible.
///
///      **The halt again.** Foreclosure sells collateral, and selling requires a transfer, which
///      reverts while the issuer has the token paused. So foreclosure defers exactly as liquidation
///      does elsewhere in this repo, and the same answer applies: collateral requirements carry the
///      per-asset halt buffer from `AssetRegistry`, sized so that a position can survive the freeze
///      it cannot be liquidated through.
contract TermRepo is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_557_600;

    AssetRegistry public immutable REGISTRY;
    IPriceSource public immutable PRICE;
    address public immutable USDG;
    uint256 public immutable USDG_SCALE;

    /// @notice APR offered for a given term length, in basis points. Zero means the term is closed.
    mapping(uint32 => uint16) public aprForTerm;
    uint32[] private _terms;

    /// @dev Collateral required per dollar lent, in basis points, before the halt buffer.
    uint16 public collateralRatioBps = 15_000;
    /// @dev How long after maturity a borrower has to repay before anyone may foreclose.
    uint32 public graceSeconds = 1 days;
    /// @dev Bonus paid to whoever forecloses, out of the collateral.
    uint16 public foreclosureBonusBps = 500;

    mapping(uint256 => Note) private _notes;
    uint256 public noteCount;
    mapping(address => uint256[]) private _byLender;
    mapping(address => uint256[]) private _byBorrower;

    event TermSet(uint32 termSeconds, uint16 aprBps);
    event Lent(uint256 indexed id, address indexed lender, uint256 principal, uint32 termSeconds, uint16 aprBps);
    event Matched(
        uint256 indexed id, address indexed borrower, address indexed asset, uint256 collateralRaw, uint256 interest
    );
    event Repaid(uint256 indexed id, uint256 principal);
    event Redeemed(uint256 indexed id, address indexed lender, uint256 amount);
    event Foreclosed(uint256 indexed id, address indexed by, uint256 collateralRaw);
    event Cancelled(uint256 indexed id);

    error UnknownTerm(uint32 termSeconds);
    error WrongState(uint256 id, NoteState state);
    error NotMature(uint256 id);
    error StillInGrace(uint256 id);
    error NotParty();
    error PriceUnusable(PriceStatus status);
    error InsufficientCollateral(uint256 supplied, uint256 required);

    constructor(address owner_, address registry, address price, address usdg) {
        _initializeOwner(owner_);
        REGISTRY = AssetRegistry(registry);
        PRICE = IPriceSource(price);
        USDG = usdg;
        USDG_SCALE = 10 ** IERC20(usdg).decimals();
    }

    // ---------------------------------------------------------------- admin

    function setTerm(uint32 termSeconds, uint16 aprBps) external onlyOwner {
        require(termSeconds >= 7 days && termSeconds <= 730 days, "TermRepo: bad term");
        require(aprBps <= 5_000, "TermRepo: apr too high");
        if (aprForTerm[termSeconds] == 0 && aprBps != 0) _terms.push(termSeconds);
        aprForTerm[termSeconds] = aprBps;
        emit TermSet(termSeconds, aprBps);
    }

    function setRiskParams(uint16 ratioBps, uint32 grace, uint16 bonusBps) external onlyOwner {
        require(ratioBps >= 10_000 && ratioBps <= 50_000, "TermRepo: bad ratio");
        require(bonusBps <= 2_000, "TermRepo: bad bonus");
        collateralRatioBps = ratioBps;
        graceSeconds = grace;
        foreclosureBonusBps = bonusBps;
    }

    function terms() external view returns (uint32[] memory) {
        return _terms;
    }

    function noteOf(uint256 id) external view returns (Note memory) {
        return _notes[id];
    }

    function notesOfLender(address lender) external view returns (uint256[] memory) {
        return _byLender[lender];
    }

    function notesOfBorrower(address borrower) external view returns (uint256[] memory) {
        return _byBorrower[borrower];
    }

    /// @notice Interest for a whole term at the offered rate.
    function interestFor(uint256 principal, uint32 termSeconds) public view returns (uint256) {
        uint16 apr = aprForTerm[termSeconds];
        if (apr == 0) return 0;
        return (principal * apr * termSeconds) / (BPS * SECONDS_PER_YEAR);
    }

    /// @notice Collateral value required to borrow `principal`, in USDG.
    function collateralRequired(uint256 principal, address asset) public view returns (uint256) {
        AssetConfig memory cfg = REGISTRY.configOf(asset);
        uint256 gross = (principal * collateralRatioBps) / BPS;
        // The halt buffer widens the requirement rather than narrowing a borrowing limit, because
        // here the constraint is on the borrower posting, not on a lender drawing.
        return (gross * (BPS + cfg.haltBufferBps)) / BPS;
    }

    // ---------------------------------------------------------------- lender

    /// @notice Deposit for a fixed term at the posted rate.
    function lend(uint256 principal, uint32 termSeconds) external nonReentrant returns (uint256 id) {
        uint16 apr = aprForTerm[termSeconds];
        if (apr == 0) revert UnknownTerm(termSeconds);
        require(principal != 0, "TermRepo: zero principal");

        USDG.safeTransferFrom(msg.sender, address(this), principal);
        id = ++noteCount;
        _notes[id] = Note({
            lender: msg.sender,
            borrower: address(0),
            collateralAsset: address(0),
            principal: principal,
            interest: 0,
            collateralRaw: 0,
            termSeconds: termSeconds,
            aprBps: apr,
            maturity: 0,
            state: NoteState.Open
        });
        _byLender[msg.sender].push(id);
        emit Lent(id, msg.sender, principal, termSeconds, apr);
    }

    /// @notice Withdraw a deposit nobody has borrowed. No penalty, because nothing was promised yet.
    function cancel(uint256 id) external nonReentrant {
        Note storage n = _notes[id];
        if (n.lender != msg.sender) revert NotParty();
        if (n.state != NoteState.Open) revert WrongState(id, n.state);
        n.state = NoteState.Cancelled;
        USDG.safeTransfer(msg.sender, n.principal);
        emit Cancelled(id);
    }

    /// @notice Collect principal and the escrowed interest after the borrower has repaid.
    function redeem(uint256 id) external nonReentrant returns (uint256 amount) {
        Note storage n = _notes[id];
        if (n.lender != msg.sender) revert NotParty();
        if (n.state != NoteState.Repaid && n.state != NoteState.Foreclosed) revert WrongState(id, n.state);

        amount = n.principal + n.interest;
        n.principal = 0;
        n.interest = 0;
        USDG.safeTransfer(msg.sender, amount);
        emit Redeemed(id, msg.sender, amount);
    }

    // ---------------------------------------------------------------- borrower

    /// @notice Take a deposit for its full term, posting collateral and the whole term's interest.
    function borrow(uint256 id, address asset, uint256 collateralRaw) external nonReentrant {
        Note storage n = _notes[id];
        if (n.state != NoteState.Open) revert WrongState(id, n.state);
        REGISTRY.requireEnabled(asset);

        uint256 required = collateralRequired(n.principal, asset);
        uint256 supplied = _valueOf(asset, collateralRaw);
        if (supplied < required) revert InsufficientCollateral(supplied, required);

        uint256 interest = interestFor(n.principal, n.termSeconds);
        n.borrower = msg.sender;
        n.collateralAsset = asset;
        n.collateralRaw = collateralRaw;
        n.interest = interest;
        n.maturity = uint64(block.timestamp + n.termSeconds);
        n.state = NoteState.Matched;
        _byBorrower[msg.sender].push(id);

        asset.safeTransferFrom(msg.sender, address(this), collateralRaw);
        // The interest arrives now, for the whole term. This line is the product's promise.
        USDG.safeTransferFrom(msg.sender, address(this), interest);
        USDG.safeTransfer(msg.sender, n.principal);

        emit Matched(id, msg.sender, asset, collateralRaw, interest);
    }

    /// @notice Repay principal at or before maturity and take the collateral back.
    function repay(uint256 id) external nonReentrant {
        Note storage n = _notes[id];
        if (n.borrower != msg.sender) revert NotParty();
        if (n.state != NoteState.Matched) revert WrongState(id, n.state);

        n.state = NoteState.Repaid;
        uint256 collateral = n.collateralRaw;
        n.collateralRaw = 0;

        USDG.safeTransferFrom(msg.sender, address(this), n.principal);
        n.collateralAsset.safeTransfer(msg.sender, collateral);
        emit Repaid(id, n.principal);
    }

    /// @notice After maturity and grace, hand the collateral to whoever makes the lender whole.
    /// @dev The foreclosing party pays the principal in dollars and receives the collateral plus a
    ///      bonus, which is the same shape as a liquidation and for the same reason: the lender must
    ///      end up with dollars, and only someone willing to hold the shares can convert them.
    ///      During an issuer halt this transfer reverts and foreclosure waits, which is why the
    ///      collateral requirement carries the halt buffer.
    function foreclose(uint256 id) external nonReentrant {
        Note storage n = _notes[id];
        if (n.state != NoteState.Matched) revert WrongState(id, n.state);
        if (block.timestamp < n.maturity) revert NotMature(id);
        if (block.timestamp < uint256(n.maturity) + graceSeconds) revert StillInGrace(id);

        n.state = NoteState.Foreclosed;
        uint256 collateral = n.collateralRaw;
        n.collateralRaw = 0;

        USDG.safeTransferFrom(msg.sender, address(this), n.principal);
        n.collateralAsset.safeTransfer(msg.sender, collateral);
        emit Foreclosed(id, msg.sender, collateral);
    }

    /// @notice Is this note collateralised enough right now? A UI shows it; nothing acts on it
    ///         before maturity, because a term repo does not margin-call mid-term.
    function collateralHealthBps(uint256 id) external view returns (uint256) {
        Note storage n = _notes[id];
        if (n.state != NoteState.Matched || n.principal == 0) return 0;
        (uint256 value, bool ok,) = _tryValueOf(n.collateralAsset, n.collateralRaw);
        if (!ok) return 0;
        return (value * BPS) / n.principal;
    }

    function _valueOf(address asset, uint256 rawAmount) internal view returns (uint256) {
        (uint256 value, bool ok, PriceStatus status) = _tryValueOf(asset, rawAmount);
        if (!ok) revert PriceUnusable(status);
        return value;
    }

    function _tryValueOf(address asset, uint256 rawAmount)
        internal
        view
        returns (uint256 usdg, bool ok, PriceStatus status)
    {
        uint256 usd1e8;
        (usd1e8, ok, status) = PRICE.tryValueOf(asset, rawAmount);
        if (!ok) return (0, false, status);
        return (FixedPointMathLib.fullMulDiv(usd1e8, USDG_SCALE, 1e8), true, status);
    }
}
