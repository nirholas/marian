// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {AssetRegistry, AssetConfig} from "../core/AssetRegistry.sol";
import {Corporate} from "../core/Corporate.sol";
import {IPriceSource, PriceStatus} from "../interfaces/IPriceSource.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @notice One borrower's position in one ticker.
struct Loan {
    uint256 collateralRaw;
    /// @dev Debt in index units. Multiply by `borrowIndex` for dollars owed.
    uint256 debtUnits;
    /// @dev When a keeper marked this position unsafe. Non-zero survives a halt.
    uint64 flaggedAt;
    address flaggedBy;
    /// @dev Principal booked against the asset's shared notional cap. Tracked separately from the
    ///      debt because accrued interest must never be released from a cap it was never added to.
    uint256 bookedNotional;
}

/// @title CreditLine
/// @notice Cash without selling.
///
/// @dev **The product.** "Get cash without selling." Nobody needs that explained, and the reason to
///      want it is the whole marketing campaign: a holder who sells a winner pays tax on it and
///      gives up the position, and a holder who borrows against it does neither. Every mechanism
///      below is hidden from that sentence.
///
///      **The mechanism is a per-ticker haircut engine the borrower never sees.** They see one
///      number, how much cash they can take. It is `collateral value * maxLtv * (1 - haltBuffer)`,
///      and the second factor is the part that has no analogue on any other chain.
///
///      **Why a halt buffer exists at all.** A Robinhood equity can be paused by its issuer, and
///      while it is, every transfer reverts. Seizing collateral is a transfer. So liquidation is
///      not slow or expensive during a halt, it is impossible, at any price, for an interval nobody
///      can bound in advance. A liquidator with infinite capital and a 100% discount cannot act.
///      No mainnet collateral has ever had that property, and lending against it as though it were
///      ordinary collateral is how a protocol discovers it has written an option it never priced.
///
///      Three things price it:
///
///      * **The buffer**, on top of the ordinary loan-to-value ratio. It is the premium the
///        borrower pays for an option the issuer holds and they sold.
///      * **Flagging.** Any keeper may mark a position unsafe the moment before a halt and is paid
///        out of the penalty when it is finally liquidated. A halt is not an escape from the
///        penalty, and keepers are paid to watch rather than only to act.
///      * **Ceilings sized to measured on-chain depth**, in `AssetRegistry`, because what a
///        liquidator could actually sell here is the only thing that makes a liquidation solvent.
contract CreditLine is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAW_ONE = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_557_600;

    AssetRegistry public immutable REGISTRY;
    IPriceSource public immutable PRICE;
    address public immutable USDG;
    uint256 public immutable USDG_SCALE;

    // ---- lending pool
    uint256 public totalBorrows;
    uint256 public borrowIndex = WAD;
    uint64 public lastAccrual;
    uint256 public totalSupplyShares;
    mapping(address => uint256) public supplySharesOf;
    uint256 public reserves;

    // ---- interest rate model, a two-slope kink
    uint256 public baseRateWad = 0.02e18;
    uint256 public slope1Wad = 0.08e18;
    uint256 public slope2Wad = 1.0e18;
    uint256 public kinkBps = 8_000;
    uint256 public reserveFactorBps = 1_000;

    // ---- liquidation
    uint256 public liquidationBonusBps = 800;
    uint256 public closeFactorBps = 5_000;
    /// @dev Share of the liquidation penalty paid to whoever flagged the position first.
    uint256 public flagRewardBps = 2_500;

    mapping(address => mapping(address => Loan)) private _loans;
    mapping(address => bool) public isKeeper;

    event Supplied(address indexed lp, uint256 amount, uint256 shares);
    event Redeemed(address indexed lp, uint256 shares, uint256 amount);
    event Locked(address indexed borrower, address indexed asset, uint256 qtyRaw);
    event Unlocked(address indexed borrower, address indexed asset, uint256 qtyRaw);
    event Drawn(address indexed borrower, address indexed asset, uint256 amount);
    event Repaid(address indexed borrower, address indexed asset, uint256 amount);
    event Flagged(address indexed borrower, address indexed asset, address indexed keeper);
    event Liquidated(
        address indexed borrower, address indexed asset, address liquidator, uint256 repaid, uint256 seizedRaw
    );
    event ParamsSet(uint256 baseRateWad, uint256 slope1Wad, uint256 slope2Wad, uint256 kinkBps, uint256 reserveBps);

    error NotHealthy(address borrower, address asset);
    error StillHealthy(address borrower, address asset);
    error NothingBorrowed();
    error InsufficientCash(uint256 requested, uint256 available);
    error PriceUnusable(PriceStatus status);
    error NotKeeper();
    error AlreadyFlagged();

    constructor(address owner_, address registry, address price, address usdg) {
        _initializeOwner(owner_);
        REGISTRY = AssetRegistry(registry);
        PRICE = IPriceSource(price);
        USDG = usdg;
        USDG_SCALE = 10 ** IERC20(usdg).decimals();
        lastAccrual = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- admin

    function setRateModel(uint256 base, uint256 slope1, uint256 slope2, uint256 kink, uint256 reserveBps)
        external
        onlyOwner
    {
        require(kink != 0 && kink < BPS, "CreditLine: bad kink");
        require(reserveBps <= 5_000, "CreditLine: bad reserve factor");
        require(base <= 1e18 && slope1 <= 5e18 && slope2 <= 50e18, "CreditLine: rate too high");
        accrue();
        baseRateWad = base;
        slope1Wad = slope1;
        slope2Wad = slope2;
        kinkBps = kink;
        reserveFactorBps = reserveBps;
        emit ParamsSet(base, slope1, slope2, kink, reserveBps);
    }

    function setLiquidationParams(uint256 bonusBps, uint256 closeBps, uint256 flagBps) external onlyOwner {
        require(bonusBps <= 3_000 && closeBps <= BPS && flagBps <= BPS, "CreditLine: bad liquidation params");
        liquidationBonusBps = bonusBps;
        closeFactorBps = closeBps;
        flagRewardBps = flagBps;
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
    }

    // ---------------------------------------------------------------- interest

    function cash() public view returns (uint256) {
        uint256 balance = IERC20(USDG).balanceOf(address(this));
        return balance > reserves ? balance - reserves : 0;
    }

    function utilizationBps() public view returns (uint256) {
        uint256 supplied = cash() + totalBorrows;
        if (supplied == 0) return 0;
        return (totalBorrows * BPS) / supplied;
    }

    /// @notice Annual borrow rate at the current utilisation, in wad.
    function borrowRateWad() public view returns (uint256) {
        uint256 u = utilizationBps();
        if (u <= kinkBps) {
            return baseRateWad + (slope1Wad * u) / kinkBps;
        }
        uint256 excess = u - kinkBps;
        return baseRateWad + slope1Wad + (slope2Wad * excess) / (BPS - kinkBps);
    }

    /// @notice Fold elapsed interest into the index. Idempotent within a block.
    function accrue() public {
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return;
        lastAccrual = uint64(block.timestamp);
        if (totalBorrows == 0) return;

        // Simple interest over the elapsed window. Compounding happens because `accrue` runs on
        // every state change, and a linear step between them is the standard approximation; over a
        // one-day gap at 10% the difference from continuous compounding is under a basis point.
        uint256 interest = (totalBorrows * borrowRateWad() * elapsed) / (WAD * SECONDS_PER_YEAR);
        if (interest == 0) return;

        uint256 toReserves = (interest * reserveFactorBps) / BPS;
        reserves += toReserves;
        borrowIndex += (borrowIndex * interest) / totalBorrows;
        totalBorrows += interest;
    }

    // ---------------------------------------------------------------- supply side

    function supply(uint256 amount) external nonReentrant returns (uint256 shares) {
        require(amount != 0, "CreditLine: zero supply");
        accrue();
        uint256 poolValue = cash() + totalBorrows;
        USDG.safeTransferFrom(msg.sender, address(this), amount);
        shares = totalSupplyShares == 0 ? amount : FixedPointMathLib.fullMulDiv(amount, totalSupplyShares, poolValue);
        require(shares != 0, "CreditLine: zero shares");
        totalSupplyShares += shares;
        supplySharesOf[msg.sender] += shares;
        emit Supplied(msg.sender, amount, shares);
    }

    function redeem(uint256 shares) external nonReentrant returns (uint256 amount) {
        require(shares != 0 && shares <= supplySharesOf[msg.sender], "CreditLine: bad shares");
        accrue();
        amount = FixedPointMathLib.fullMulDiv(shares, cash() + totalBorrows, totalSupplyShares);
        uint256 available = cash();
        if (amount > available) revert InsufficientCash(amount, available);
        supplySharesOf[msg.sender] -= shares;
        totalSupplyShares -= shares;
        USDG.safeTransfer(msg.sender, amount);
        emit Redeemed(msg.sender, shares, amount);
    }

    // ---------------------------------------------------------------- borrow side

    /// @notice Lock shares and take cash in one call. The retail entry point.
    function borrowAgainst(address asset, uint256 qtyRaw, uint256 cashWanted) external nonReentrant {
        _lock(asset, qtyRaw);
        if (cashWanted != 0) _draw(asset, cashWanted);
    }

    /// @notice Pay back and take the shares out, in one call.
    /// @param repayAmount Pass `type(uint256).max` to clear the debt exactly.
    function repayAndUnlock(address asset, uint256 repayAmount, uint256 qtyRaw) external nonReentrant {
        if (repayAmount != 0) _repay(asset, repayAmount);
        if (qtyRaw != 0) _unlock(asset, qtyRaw);
    }

    function lock(address asset, uint256 qtyRaw) external nonReentrant {
        _lock(asset, qtyRaw);
    }

    function draw(address asset, uint256 amount) external nonReentrant {
        _draw(asset, amount);
    }

    function repay(address asset, uint256 amount) external nonReentrant {
        _repay(asset, amount);
    }

    function unlock(address asset, uint256 qtyRaw) external nonReentrant {
        _unlock(asset, qtyRaw);
    }

    function _lock(address asset, uint256 qtyRaw) internal {
        REGISTRY.requireEnabled(asset);
        require(qtyRaw != 0, "CreditLine: zero collateral");
        accrue();
        asset.safeTransferFrom(msg.sender, address(this), qtyRaw);
        _loans[msg.sender][asset].collateralRaw += qtyRaw;
        emit Locked(msg.sender, asset, qtyRaw);
    }

    function _draw(address asset, uint256 amount) internal {
        AssetConfig memory cfg = REGISTRY.requireEnabled(asset);
        accrue();
        uint256 available = cash();
        if (amount > available) revert InsufficientCash(amount, available);

        Loan storage loan = _loans[msg.sender][asset];
        loan.debtUnits += FixedPointMathLib.fullMulDiv(amount, WAD, borrowIndex);
        totalBorrows += amount;

        loan.bookedNotional += amount;
        REGISTRY.adjustNotional(asset, int256(_toUsd1e8(amount)));

        if (!_isHealthy(loan, cfg, _valueOf(asset, loan.collateralRaw))) revert NotHealthy(msg.sender, asset);

        USDG.safeTransfer(msg.sender, amount);
        emit Drawn(msg.sender, asset, amount);
    }

    function _repay(address asset, uint256 amount) internal {
        accrue();
        Loan storage loan = _loans[msg.sender][asset];
        uint256 owed = debtOf(msg.sender, asset);
        if (owed == 0) revert NothingBorrowed();
        if (amount > owed) amount = owed;

        USDG.safeTransferFrom(msg.sender, address(this), amount);
        uint256 units = FixedPointMathLib.fullMulDiv(amount, WAD, borrowIndex);
        if (units > loan.debtUnits) units = loan.debtUnits;
        loan.debtUnits -= units;
        totalBorrows = totalBorrows > amount ? totalBorrows - amount : 0;
        _releaseNotional(loan, asset, amount);
        if (loan.debtUnits == 0) {
            loan.flaggedAt = 0;
            loan.flaggedBy = address(0);
        }
        emit Repaid(msg.sender, asset, amount);
    }

    function _unlock(address asset, uint256 qtyRaw) internal {
        accrue();
        Loan storage loan = _loans[msg.sender][asset];
        require(qtyRaw <= loan.collateralRaw, "CreditLine: not enough collateral");
        loan.collateralRaw -= qtyRaw;

        if (loan.debtUnits != 0) {
            AssetConfig memory cfg = REGISTRY.configOf(asset);
            if (!_isHealthy(loan, cfg, _valueOf(asset, loan.collateralRaw))) revert NotHealthy(msg.sender, asset);
        }
        asset.safeTransfer(msg.sender, qtyRaw);
        emit Unlocked(msg.sender, asset, qtyRaw);
    }

    // ---------------------------------------------------------------- health

    function loanOf(address borrower, address asset) external view returns (Loan memory) {
        return _loans[borrower][asset];
    }

    /// @notice Dollars owed right now, at 1e8 scaled into USDG units.
    function debtOf(address borrower, address asset) public view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(_loans[borrower][asset].debtUnits, borrowIndex, WAD);
    }

    /// @notice The most this borrower could take against what they have locked.
    function borrowCapacity(address borrower, address asset) public view returns (uint256) {
        Loan storage loan = _loans[borrower][asset];
        AssetConfig memory cfg = REGISTRY.configOf(asset);
        (uint256 value, bool ok,) = _tryValueOf(asset, loan.collateralRaw);
        if (!ok) return 0;
        return _capacity(value, cfg);
    }

    function isHealthy(address borrower, address asset) public view returns (bool) {
        Loan storage loan = _loans[borrower][asset];
        if (loan.debtUnits == 0) return true;
        (uint256 value, bool ok,) = _tryValueOf(asset, loan.collateralRaw);
        if (!ok) return true; // A price the oracle will not serve cannot condemn a position.
        return _isHealthy(loan, REGISTRY.configOf(asset), value);
    }

    function _isHealthy(Loan storage loan, AssetConfig memory cfg, uint256 collateralUsdg)
        internal
        view
        returns (bool)
    {
        uint256 owed = FixedPointMathLib.fullMulDiv(loan.debtUnits, borrowIndex, WAD);
        return owed <= _capacity(collateralUsdg, cfg);
    }

    /// @dev Loan-to-value, then the halt buffer on top. $17,000 of NVDA at 65% and a 25% buffer
    ///      supports $8,287, not $11,050. The difference is the price of the issuer's option.
    function _capacity(uint256 collateralUsdg, AssetConfig memory cfg) internal pure returns (uint256) {
        uint256 gross = (collateralUsdg * cfg.maxLtvBps) / BPS;
        return (gross * (BPS - cfg.haltBufferBps)) / BPS;
    }

    // ---------------------------------------------------------------- liquidation

    /// @notice Mark a position unsafe. Pays out of the penalty when it is eventually liquidated.
    /// @dev The point of flagging is that it works during a halt, when liquidation does not. A
    ///      keeper who spots the breach the instant before the issuer freezes the token is paid for
    ///      spotting it, however long the freeze lasts.
    function flag(address borrower, address asset) external {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        accrue();
        Loan storage loan = _loans[borrower][asset];
        if (loan.debtUnits == 0) revert NothingBorrowed();
        if (loan.flaggedAt != 0) revert AlreadyFlagged();

        (uint256 value, bool ok, PriceStatus status) = _tryValueOf(asset, loan.collateralRaw);
        if (!ok) revert PriceUnusable(status);
        if (_isHealthy(loan, REGISTRY.configOf(asset), value)) revert StillHealthy(borrower, asset);

        loan.flaggedAt = uint64(block.timestamp);
        loan.flaggedBy = msg.sender;
        emit Flagged(borrower, asset, msg.sender);
    }

    /// @notice Repay part of an unsafe loan and seize collateral at a discount.
    function liquidate(address borrower, address asset, uint256 repayAmount)
        external
        nonReentrant
        returns (uint256 seizedRaw)
    {
        accrue();
        Loan storage loan = _loans[borrower][asset];
        if (loan.debtUnits == 0) revert NothingBorrowed();

        AssetConfig memory cfg = REGISTRY.configOf(asset);
        (uint256 value, bool ok, PriceStatus status) = _tryValueOf(asset, loan.collateralRaw);
        if (!ok) revert PriceUnusable(status);
        if (_isHealthy(loan, cfg, value)) revert StillHealthy(borrower, asset);

        uint256 owed = FixedPointMathLib.fullMulDiv(loan.debtUnits, borrowIndex, WAD);
        uint256 maxRepay = (owed * closeFactorBps) / BPS;
        if (repayAmount > maxRepay) repayAmount = maxRepay;
        require(repayAmount != 0, "CreditLine: nothing to repay");

        USDG.safeTransferFrom(msg.sender, address(this), repayAmount);
        uint256 units = FixedPointMathLib.fullMulDiv(repayAmount, WAD, borrowIndex);
        if (units > loan.debtUnits) units = loan.debtUnits;
        loan.debtUnits -= units;
        totalBorrows = totalBorrows > repayAmount ? totalBorrows - repayAmount : 0;
        _releaseNotional(loan, asset, repayAmount);

        // Seize the repaid dollars plus the bonus, priced off the same oracle reading.
        uint256 seizeUsdg = (repayAmount * (BPS + liquidationBonusBps)) / BPS;
        seizedRaw = FixedPointMathLib.fullMulDiv(loan.collateralRaw, seizeUsdg, value);
        if (seizedRaw > loan.collateralRaw) seizedRaw = loan.collateralRaw;
        loan.collateralRaw -= seizedRaw;

        uint256 bonusRaw = FixedPointMathLib.fullMulDiv(seizedRaw, liquidationBonusBps, BPS + liquidationBonusBps);
        uint256 flaggerCut;
        address flagger = loan.flaggedBy;
        if (flagger != address(0) && flagger != msg.sender) {
            flaggerCut = (bonusRaw * flagRewardBps) / BPS;
        }

        // This transfer is the one that reverts during a halt, which is exactly why flagging
        // exists: the claim is already recorded and survives until the token moves again.
        if (flaggerCut != 0) asset.safeTransfer(flagger, flaggerCut);
        asset.safeTransfer(msg.sender, seizedRaw - flaggerCut);

        if (loan.debtUnits == 0) {
            loan.flaggedAt = 0;
            loan.flaggedBy = address(0);
        }
        emit Liquidated(borrower, asset, msg.sender, repayAmount, seizedRaw);
    }

    /// @dev Release at most what was booked. Interest repaid above principal was never counted
    ///      against the cap, so releasing it would let the cap drift upward with every repayment.
    function _releaseNotional(Loan storage loan, address asset, uint256 amount) internal {
        uint256 booked = loan.bookedNotional;
        if (booked == 0) return;
        uint256 release = amount > booked ? booked : amount;
        loan.bookedNotional = booked - release;
        REGISTRY.adjustNotional(asset, -int256(_toUsd1e8(release)));
    }

    // ---------------------------------------------------------------- units

    function _toUsd1e8(uint256 usdgAmount) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(usdgAmount, 1e8, USDG_SCALE);
    }

    function _valueOf(address asset, uint256 rawAmount) internal view returns (uint256) {
        (uint256 value, bool ok, PriceStatus status) = _tryValueOf(asset, rawAmount);
        if (!ok) revert PriceUnusable(status);
        return value;
    }

    /// @dev The oracle answers in dollars at 1e8; this pool keeps its books in USDG units.
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
