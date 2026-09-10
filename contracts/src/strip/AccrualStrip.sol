// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {AssetRegistry} from "../core/AssetRegistry.sol";
import {Corporate} from "../core/Corporate.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {IERC20} from "../interfaces/IERC20.sol";

enum StripState {
    None,
    Offered,
    Funded,
    Settled,
    Cancelled
}

/// @notice One holder selling the payouts their shares will earn over a fixed window.
struct Strip {
    address holder;
    address buyer;
    address asset;
    uint256 qtyRaw;
    /// @dev `uiMultiplier` when the window opened. The entire settlement is this against the one
    ///      at maturity.
    uint256 startMultiplier;
    uint256 endMultiplier;
    uint256 askUsdg;
    uint64 maturity;
    StripState state;
}

/// @title AccrualStrip
/// @notice Sell the payouts your shares earn over the next N days, for cash today.
///
/// @dev **This product exists because of one measurement.** On 2026-09-10 every one of the 38
///      liquid tokenized equities on Robinhood Chain was read directly: exactly eight had a
///      `uiMultiplier` above 1e18, and they were exactly the eight that pay a distribution. SGOV
///      sat at 1.005102, UPS at 1.002209, JNJ at 1.0000215; TSLA, GME, GLD, SLV, META and every
///      other non-payer sat at exactly 1e18. Sampled backwards through the chain's whole history,
///      each of those multipliers is a step function that moves once per payout and never falls.
///
///      So on this chain a distribution is not a transfer to holders. It is an increase in how many
///      economic shares one raw unit carries, and it is the only observable form a payout takes.
///      That makes it strippable in the most literal way available anywhere in DeFi.
///
///      **The settlement needs no price.** A holder locks `qtyRaw` raw units at multiplier `m0`.
///      At maturity the multiplier is `m1`. The buyer receives `qtyRaw * (m1 - m0) / m1` raw units
///      and the holder keeps the rest, which is `qtyRaw * m0 / m1` raw units carrying exactly
///      `qtyRaw * m0` economic shares... precisely what the holder started with. The holder is whole
///      in shares, the buyer has the accrual, and no oracle, no price and no counterparty solvency
///      entered the calculation. A reverse split moves `m1` below `m0` and pays the buyer nothing,
///      which is correct: a reverse split is not a payout.
///
///      **Honesty about size.** For most single names the accrual over a quarter is a few basis
///      points, and the interface says so by showing the measured history rather than an annualised
///      projection. The instrument is worth having because of SGOV and the other funds, where the
///      accrual is a real, regular, T-bill-shaped yield, and because it is the only way to separate
///      a payout from a share on this chain at all.
contract AccrualStrip is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    AssetRegistry public immutable REGISTRY;
    address public immutable USDG;

    uint256 public constant MIN_WINDOW = 7 days;
    uint256 public constant MAX_WINDOW = 730 days;

    /// @dev Protocol take on the cash paid, in basis points.
    uint16 public feeBps = 50;
    address public feeSink;

    mapping(uint256 => Strip) private _strips;
    uint256 public stripCount;
    mapping(address => uint256[]) private _byHolder;

    event Offered(
        uint256 indexed id, address indexed holder, address indexed asset, uint256 qtyRaw, uint256 askUsdg, uint64 maturity
    );
    event Funded(uint256 indexed id, address indexed buyer, uint256 paidUsdg, uint256 feeUsdg);
    event SettledStrip(uint256 indexed id, uint256 endMultiplier, uint256 buyerRaw, uint256 holderRaw);
    event Cancelled(uint256 indexed id);
    event FeeSet(uint16 feeBps, address sink);

    error BadWindow(uint64 maturity);
    error WrongState(uint256 id, StripState state);
    error NotMature(uint256 id);
    error NotHolder();

    constructor(address owner_, address registry, address usdg, address sink) {
        _initializeOwner(owner_);
        REGISTRY = AssetRegistry(registry);
        USDG = usdg;
        feeSink = sink;
    }

    function setFee(uint16 bps, address sink) external onlyOwner {
        require(bps <= 500 && sink != address(0), "AccrualStrip: bad fee");
        feeBps = bps;
        feeSink = sink;
        emit FeeSet(bps, sink);
    }

    function stripOf(uint256 id) external view returns (Strip memory) {
        return _strips[id];
    }

    function stripsOf(address holder) external view returns (uint256[] memory) {
        return _byHolder[holder];
    }

    /// @notice Lock shares and offer their future payouts for a lump sum.
    function offer(address asset, uint256 qtyRaw, uint256 askUsdg, uint64 maturity)
        external
        nonReentrant
        returns (uint256 id)
    {
        REGISTRY.requireEnabled(asset);
        require(qtyRaw != 0 && askUsdg != 0, "AccrualStrip: zero terms");
        if (maturity <= block.timestamp) revert BadWindow(maturity);
        uint256 window = maturity - block.timestamp;
        if (window < MIN_WINDOW || window > MAX_WINDOW) revert BadWindow(maturity);

        // Read the multiplier before the transfer, so a token that moves it inside a hook cannot
        // open a window that has already accrued.
        uint256 startMultiplier = Corporate.multiplierOf(asset);
        asset.safeTransferFrom(msg.sender, address(this), qtyRaw);

        id = ++stripCount;
        _strips[id] = Strip({
            holder: msg.sender,
            buyer: address(0),
            asset: asset,
            qtyRaw: qtyRaw,
            startMultiplier: startMultiplier,
            endMultiplier: 0,
            askUsdg: askUsdg,
            maturity: maturity,
            state: StripState.Offered
        });
        _byHolder[msg.sender].push(id);
        emit Offered(id, msg.sender, asset, qtyRaw, askUsdg, maturity);
    }

    /// @notice Take the other side: pay the ask, own the window's payouts.
    function fund(uint256 id) external nonReentrant {
        Strip storage s = _strips[id];
        if (s.state != StripState.Offered) revert WrongState(id, s.state);
        if (block.timestamp >= s.maturity) revert BadWindow(s.maturity);

        s.state = StripState.Funded;
        s.buyer = msg.sender;

        uint256 fee = (s.askUsdg * feeBps) / 10_000;
        USDG.safeTransferFrom(msg.sender, s.holder, s.askUsdg - fee);
        if (fee != 0) USDG.safeTransferFrom(msg.sender, feeSink, fee);
        emit Funded(id, msg.sender, s.askUsdg, fee);
    }

    /// @notice Withdraw an offer nobody took.
    function cancel(uint256 id) external nonReentrant {
        Strip storage s = _strips[id];
        if (s.holder != msg.sender) revert NotHolder();
        if (s.state != StripState.Offered) revert WrongState(id, s.state);
        s.state = StripState.Cancelled;
        s.asset.safeTransfer(msg.sender, s.qtyRaw);
        emit Cancelled(id);
    }

    /// @notice Close the window and split the shares. Permissionless.
    /// @dev No price is read here and none is needed. If the token is halted the transfers revert
    ///      and settlement simply happens later, at the same multipliers, for the same amounts: a
    ///      halt delays this settlement without changing its outcome by a single wei, which is not
    ///      true of any other product in this repo.
    function settle(uint256 id) external nonReentrant returns (uint256 buyerRaw, uint256 holderRaw) {
        Strip storage s = _strips[id];
        if (s.state != StripState.Funded) revert WrongState(id, s.state);
        if (block.timestamp < s.maturity) revert NotMature(id);

        uint256 endMultiplier = Corporate.multiplierOf(s.asset);
        s.endMultiplier = endMultiplier;
        s.state = StripState.Settled;

        buyerRaw = accrualShare(s.qtyRaw, s.startMultiplier, endMultiplier);
        holderRaw = s.qtyRaw - buyerRaw;

        if (buyerRaw != 0) s.asset.safeTransfer(s.buyer, buyerRaw);
        if (holderRaw != 0) s.asset.safeTransfer(s.holder, holderRaw);
        emit SettledStrip(id, endMultiplier, buyerRaw, holderRaw);
    }

    /// @notice The raw units representing everything that accrued between two multipliers.
    /// @dev `qty * (m1 - m0) / m1`. Floors, so the holder can never be paid out of the buyer's
    ///      share and the escrow can never be overdrawn.
    function accrualShare(uint256 qtyRaw, uint256 startMultiplier, uint256 endMultiplier)
        public
        pure
        returns (uint256)
    {
        if (endMultiplier <= startMultiplier || endMultiplier == 0) return 0;
        return FixedPointMathLib.fullMulDiv(qtyRaw, endMultiplier - startMultiplier, endMultiplier);
    }

    /// @notice What a strip would pay out if it settled right now, for a UI.
    function previewSettle(uint256 id) external view returns (uint256 buyerRaw, uint256 holderRaw) {
        Strip storage s = _strips[id];
        if (s.state != StripState.Funded && s.state != StripState.Offered) return (0, 0);
        uint256 live = IStockToken(s.asset).uiMultiplier();
        buyerRaw = accrualShare(s.qtyRaw, s.startMultiplier, live);
        holderRaw = s.qtyRaw - buyerRaw;
    }
}
