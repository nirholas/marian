// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {AssetRegistry, AssetConfig} from "../core/AssetRegistry.sol";
import {Corporate, Adjustment} from "../core/Corporate.sol";
import {IPriceSource, PriceStatus} from "../interfaces/IPriceSource.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IOptionBuyer, SeriesTerms} from "./IOptionBuyer.sol";
import {VolSurface} from "./VolSurface.sol";
import {OptionMath} from "./OptionMath.sol";

/// @notice A weekly option series. `strikePerShare1e8` is the number the user named and it never
///         changes; `strikeRaw1e8` is how the protocol stores it and it moves with corporate
///         actions. Keeping both is what lets the promise survive a dividend.
struct Series {
    address asset;
    uint64 expiry;
    bool isCall;
    bool settled;
    uint128 strikePerShare1e8;
    uint128 strikeRaw1e8;
    uint128 refMultiplier;
    uint128 settlePriceRaw1e8;
    uint64 settledAt;
    uint256 openQtyRaw;
}

/// @title PaidOrders
/// @notice Covered calls and cash-secured puts, presented as the limit order the user was going to
///         place anyway, except this one pays them.
///
/// @dev **The product.** "Name the price you would happily sell NVDA at. Get paid to wait. If it
///      gets there, you sold at your price and you keep the cash. If it does not, you just keep the
///      cash." That sentence introduces no word the user did not already know, and underneath it is
///      a fully collateralised European option venue.
///
///      **Fully collateralised, and therefore unliquidatable.** A writer's obligation is escrowed
///      in full at the moment they write: shares for a call, dollars for a put. There is no margin
///      engine, no maintenance ratio, no liquidator and no path by which a user who wrote one
///      covered call loses more than the shares they already set aside. That is not a simplifying
///      shortcut, it is the property that lets the product be described in one sentence honestly.
///      Everything a margin engine would have bought is instead bought by refusing to let anyone
///      write an option they cannot cover.
///
///      **Settlement pays out of the escrow, in the escrow's own asset.** A call settles by giving
///      the long the fraction of the escrowed shares worth `S - K`, leaving the writer shares worth
///      exactly `K`: their stock was called away at their price. A put settles by giving the long
///      `K - S` of the escrowed dollars, leaving the writer dollars worth exactly `S`: the same
///      position as having bought the stock at `K`. No settlement path needs a counterparty to
///      show up with cash, which is why no settlement path can fail because one did not.
///
///      **Halts.** While the issuer has a token paused, its transfers revert and its price is
///      disavowed. Settlement therefore defers: `settle` is permissionless and takes the first
///      oracle observation available at or after expiry, which during a halt is the first one after
///      the halt lifts. A writer is told this before they write. `docs/halts.md` is the full table.
///
///      **Corporate actions.** On this chain a dividend, a split and a reverse split are all the
///      same event: `uiMultiplier` moves. An unadjusted strike would drag a call into the money on
///      a payout the writer was entitled to keep, so every entry point re-derives the raw strike
///      from the live multiplier first. See `Corporate`.
contract PaidOrders is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAW_ONE = 1e18;

    /// @dev Friday 2026-01-02 20:00:00 UTC. Every series expires a whole number of weeks after
    ///      this instant, so liquidity concentrates on a handful of dates instead of scattering
    ///      across every second a user might type. A venue with one bid on each of a thousand
    ///      expiries has no bids.
    uint64 public constant EXPIRY_EPOCH = 1_767_384_000;
    uint64 public constant EXPIRY_PERIOD = 7 days;

    /// @dev A quote loop long enough to be worth gaming is a quote loop long enough to be a denial
    ///      of service on the write path.
    uint256 public constant MAX_BUYERS = 8;

    AssetRegistry public immutable REGISTRY;
    IPriceSource public immutable PRICE;
    VolSurface public immutable VOL;
    address public immutable USDG;
    uint256 public immutable USDG_SCALE;

    address public feeSink;
    /// @dev Continuously compounded discount rate used by the model, wad. Signed: a negative rate
    ///      is a legitimate market state and refusing to represent it would silently misprice.
    int256 public rateWad;

    address[] private _buyers;
    mapping(address => bool) public isBuyer;

    mapping(bytes32 => Series) private _series;
    bytes32[] private _seriesIds;

    /// @notice Raw units written by an address into a series, still escrowed.
    mapping(bytes32 => mapping(address => uint256)) public shortOf;
    /// @notice Raw-unit-denominated long contracts held by an address.
    mapping(bytes32 => mapping(address => uint256)) public longOf;
    /// @dev Notional booked into the registry per writer, so the exact amount is released on exit.
    mapping(bytes32 => mapping(address => uint256)) public shortNotionalUsd1e8;

    event BuyerSet(address indexed buyer, bool allowed);
    event FeeSinkSet(address indexed sink);
    event RateSet(int256 rateWad);
    event SeriesOpened(
        bytes32 indexed id, address indexed asset, uint64 expiry, bool isCall, uint256 strikePerShare1e8
    );
    event SeriesAdjusted(bytes32 indexed id, uint256 fromMultiplier, uint256 toMultiplier, uint256 newStrikeRaw1e8);
    event Written(
        bytes32 indexed id,
        address indexed writer,
        address indexed buyer,
        uint256 qtyRaw,
        uint256 grossPremiumUsdg,
        uint256 feeUsdg
    );
    event Settled(bytes32 indexed id, uint256 settlePriceRaw1e8, uint256 settledAt);
    event ShortClaimed(bytes32 indexed id, address indexed writer, uint256 qtyRaw, uint256 returnedAmount);
    event LongClaimed(bytes32 indexed id, address indexed holder, uint256 qtyRaw, uint256 payoutAmount);

    error BadExpiry(uint64 expiry);
    error BadStrike(uint256 strikeRaw1e8, uint256 spotRaw1e8);
    error NoSeries(bytes32 id);
    error NotExpired(bytes32 id);
    error AlreadySettled(bytes32 id);
    error NotSettled(bytes32 id);
    error PriceUnavailable(PriceStatus status);
    error PremiumTooLow(uint256 offered, uint256 required);
    error NoBid(bytes32 id);
    error BuyerDidNotPay(address buyer, uint256 expected, uint256 received);
    error NothingToClaim();
    error TooManyBuyers();
    error UnsupportedDecimals(address asset, uint8 decimals);

    constructor(address owner_, address registry, address price, address vol, address usdg, address sink) {
        _initializeOwner(owner_);
        REGISTRY = AssetRegistry(registry);
        PRICE = IPriceSource(price);
        VOL = VolSurface(vol);
        USDG = usdg;
        USDG_SCALE = 10 ** IERC20(usdg).decimals();
        feeSink = sink;
        emit FeeSinkSet(sink);
    }

    // ---------------------------------------------------------------- admin

    function setBuyer(address buyer, bool allowed) external onlyOwner {
        if (allowed && !isBuyer[buyer]) {
            if (_buyers.length >= MAX_BUYERS) revert TooManyBuyers();
            _buyers.push(buyer);
        } else if (!allowed && isBuyer[buyer]) {
            uint256 n = _buyers.length;
            for (uint256 i; i < n; ++i) {
                if (_buyers[i] == buyer) {
                    _buyers[i] = _buyers[n - 1];
                    _buyers.pop();
                    break;
                }
            }
        }
        isBuyer[buyer] = allowed;
        emit BuyerSet(buyer, allowed);
    }

    function setFeeSink(address sink) external onlyOwner {
        require(sink != address(0), "PaidOrders: zero sink");
        feeSink = sink;
        emit FeeSinkSet(sink);
    }

    function setRate(int256 newRateWad) external onlyOwner {
        require(newRateWad > -0.5e18 && newRateWad < 1e18, "PaidOrders: rate out of bounds");
        rateWad = newRateWad;
        emit RateSet(newRateWad);
    }

    function buyers() external view returns (address[] memory) {
        return _buyers;
    }

    // ---------------------------------------------------------------- views

    function seriesIdOf(address asset, uint64 expiry, bool isCall, uint256 strikePerShare1e8)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(asset, expiry, isCall, strikePerShare1e8));
    }

    function seriesOf(bytes32 id) external view returns (Series memory) {
        return _series[id];
    }

    function seriesCount() external view returns (uint256) {
        return _seriesIds.length;
    }

    function seriesIdAt(uint256 index) external view returns (bytes32) {
        return _seriesIds[index];
    }

    /// @notice Is this instant on the weekly expiry grid?
    function isValidExpiry(uint64 expiry) public pure returns (bool) {
        if (expiry <= EXPIRY_EPOCH) return false;
        return (expiry - EXPIRY_EPOCH) % EXPIRY_PERIOD == 0;
    }

    /// @notice The next `count` expiries on the grid, for a UI that offers "how long will you wait".
    function upcomingExpiries(uint256 count) external view returns (uint64[] memory out) {
        out = new uint64[](count);
        uint64 next = EXPIRY_EPOCH + EXPIRY_PERIOD;
        unchecked {
            uint64 elapsed = uint64(block.timestamp) > EXPIRY_EPOCH ? uint64(block.timestamp) - EXPIRY_EPOCH : 0;
            next = EXPIRY_EPOCH + ((elapsed / EXPIRY_PERIOD) + 1) * EXPIRY_PERIOD;
            for (uint256 i; i < count; ++i) {
                out[i] = next + uint64(i) * EXPIRY_PERIOD;
            }
        }
    }

    /// @notice The corporate action this chain has already scheduled against a series, if any.
    /// @dev The UI shows this before a user writes. Nothing else in DeFi can.
    function pendingAdjustment(bytes32 id) external view returns (Adjustment memory) {
        Series storage s = _series[id];
        if (s.asset == address(0)) return Adjustment({ratioWad: Corporate.ONE, effectiveAt: 0});
        return Corporate.pendingOf(s.asset);
    }

    /// @notice Spot per raw unit, at 1e8.
    function spotRawOf(address asset) public view returns (uint256) {
        return PRICE.valueOf(asset, RAW_ONE);
    }

    /// @notice What the model says one series is worth, before anyone's bid.
    /// @return premiumUsdg Model premium for `qtyRaw`, in USDG.
    /// @return volWad The volatility used.
    function modelPremium(address asset, uint64 expiry, bool isCall, uint256 strikePerShare1e8, uint256 qtyRaw)
        public
        view
        returns (uint256 premiumUsdg, uint256 volWad)
    {
        uint256 spotRaw = spotRawOf(asset);
        uint256 multiplier = Corporate.multiplierOf(asset);
        uint256 strikeRaw = Corporate.strikePerShareToRaw(strikePerShare1e8, multiplier);

        uint256 spotWad = _to18(spotRaw);
        uint256 strikeWad = _to18(strikeRaw);
        volWad = VOL.volFor(asset, spotWad, strikeWad);

        uint256 tau = expiry > block.timestamp ? OptionMath.yearsOf(expiry - block.timestamp) : 0;
        (uint256 call, uint256 put) = OptionMath.callPut(spotWad, strikeWad, tau, volWad, rateWad);
        uint256 perRaw1e8 = _from18(isCall ? call : put);
        premiumUsdg = _usdgValue(qtyRaw, perRaw1e8);
    }

    /// @notice The best bid available right now across every registered buyer.
    /// @dev A buyer that reverts or quotes zero is skipped rather than allowed to block the venue.
    function bestBid(SeriesTerms memory terms, uint256 qtyRaw)
        public
        view
        returns (address buyer, uint256 premiumUsdg)
    {
        bytes32 id = seriesIdOf(terms.asset, terms.expiry, terms.isCall, terms.strikePerShare1e8);
        uint256 n = _buyers.length;
        for (uint256 i; i < n; ++i) {
            address candidate = _buyers[i];
            try IOptionBuyer(candidate).quoteBuy(id, terms, qtyRaw) returns (uint256 bid) {
                if (bid > premiumUsdg) {
                    premiumUsdg = bid;
                    buyer = candidate;
                }
            } catch {
                continue;
            }
        }
    }

    /// @notice Everything a writer needs to see before they commit, in one call.
    /// @return premiumUsdg What they would be paid, net of protocol fee.
    /// @return feeUsdg The protocol's take.
    /// @return maxProceedsUsdg The most this position can be worth at expiry, premium included.
    /// @dev `maxProceedsUsdg` exists because the simplification stops being honest the moment the
    ///      stock rips through the strike. A covered call's upside is capped and the interface has
    ///      to say so in the same breath as the premium, in the same unit, or the first violent gap
    ///      up costs the venue the cohort it spent to acquire.
    function previewWrite(address asset, uint64 expiry, bool isCall, uint256 strikePerShare1e8, uint256 qtyRaw)
        external
        view
        returns (uint256 premiumUsdg, uint256 feeUsdg, uint256 maxProceedsUsdg, address buyer)
    {
        SeriesTerms memory terms =
            SeriesTerms({asset: asset, expiry: expiry, isCall: isCall, strikePerShare1e8: strikePerShare1e8});
        uint256 gross;
        (buyer, gross) = bestBid(terms, qtyRaw);
        AssetConfig memory cfg = REGISTRY.configOf(asset);
        feeUsdg = (gross * cfg.feeBps) / BPS;
        premiumUsdg = gross - feeUsdg;

        uint256 multiplier = Corporate.multiplierOf(asset);
        uint256 strikeRaw = Corporate.strikePerShareToRaw(strikePerShare1e8, multiplier);
        // A call caps out at the strike times the shares, plus the premium. A cash-secured put
        // caps out at the cash it locked, plus the premium: it can never be worth more than the
        // dollars already sitting in escrow.
        maxProceedsUsdg = _usdgValue(qtyRaw, strikeRaw) + premiumUsdg;
    }

    // ---------------------------------------------------------------- writing

    /// @notice Sell shares at a price you name, and get paid whether or not it gets there.
    /// @param asset The tokenized equity to escrow.
    /// @param qtyRaw Raw units of `asset` to set aside.
    /// @param strikePerShare1e8 The price the user named, in dollars per economic share at 1e8.
    /// @param expiry How long they will wait. Must be on the weekly grid.
    /// @param minPremiumUsdg Reverts unless the writer nets at least this much.
    function writeCall(
        address asset,
        uint256 qtyRaw,
        uint256 strikePerShare1e8,
        uint64 expiry,
        uint256 minPremiumUsdg
    ) external nonReentrant returns (bytes32 id, uint256 netPremiumUsdg) {
        return _write(asset, qtyRaw, strikePerShare1e8, expiry, minPremiumUsdg, true);
    }

    /// @notice Buy shares at a price you name, and get paid whether or not it gets there.
    /// @dev The cash locked is `qtyRaw * strike`, which is exactly what the shares would cost at
    ///      the named price. Nothing else is at risk.
    function writePut(
        address asset,
        uint256 qtyRaw,
        uint256 strikePerShare1e8,
        uint64 expiry,
        uint256 minPremiumUsdg
    ) external nonReentrant returns (bytes32 id, uint256 netPremiumUsdg) {
        return _write(asset, qtyRaw, strikePerShare1e8, expiry, minPremiumUsdg, false);
    }

    function _write(
        address asset,
        uint256 qtyRaw,
        uint256 strikePerShare1e8,
        uint64 expiry,
        uint256 minPremiumUsdg,
        bool isCall
    ) internal returns (bytes32 id, uint256 netPremiumUsdg) {
        AssetConfig memory cfg = REGISTRY.requireEnabled(asset);
        require(qtyRaw != 0, "PaidOrders: zero size");
        if (!isValidExpiry(expiry)) revert BadExpiry(expiry);
        if (expiry <= block.timestamp) revert BadExpiry(expiry);
        uint256 tenor = expiry - block.timestamp;
        if (tenor < cfg.minTenor || tenor > cfg.maxTenor) revert BadExpiry(expiry);

        PRICE.poke(asset);
        uint256 spotRaw = spotRawOf(asset);
        uint256 multiplier = Corporate.multiplierOf(asset);
        uint256 strikeRaw = Corporate.strikePerShareToRaw(strikePerShare1e8, multiplier);
        _requireStrikeInBand(strikeRaw, spotRaw, cfg.strikeBandBps, isCall);

        id = seriesIdOf(asset, expiry, isCall, strikePerShare1e8);
        Series storage s = _series[id];
        if (s.asset == address(0)) {
            uint8 dec = IStockToken(asset).decimals();
            // Every quantity in this contract is 1e18-raw. A token with different decimals would
            // silently scale every strike and every payoff, so it is refused at the only moment it
            // can still be refused safely.
            if (dec != 18) revert UnsupportedDecimals(asset, dec);
            s.asset = asset;
            s.expiry = expiry;
            s.isCall = isCall;
            s.strikePerShare1e8 = uint128(strikePerShare1e8);
            s.strikeRaw1e8 = uint128(strikeRaw);
            s.refMultiplier = uint128(multiplier);
            _seriesIds.push(id);
            emit SeriesOpened(id, asset, expiry, isCall, strikePerShare1e8);
        } else {
            _sync(id);
            strikeRaw = s.strikeRaw1e8;
        }

        // Escrow first. Everything after this point is spending collateral the contract holds.
        if (isCall) {
            asset.safeTransferFrom(msg.sender, address(this), qtyRaw);
        } else {
            USDG.safeTransferFrom(msg.sender, address(this), _usdgValue(qtyRaw, strikeRaw));
        }

        uint256 notionalUsd1e8 = FixedPointMathLib.fullMulDiv(qtyRaw, spotRaw, RAW_ONE);
        REGISTRY.adjustNotional(asset, int256(notionalUsd1e8));
        shortNotionalUsd1e8[id][msg.sender] += notionalUsd1e8;
        shortOf[id][msg.sender] += qtyRaw;
        s.openQtyRaw += qtyRaw;

        SeriesTerms memory terms =
            SeriesTerms({asset: asset, expiry: expiry, isCall: isCall, strikePerShare1e8: strikePerShare1e8});
        netPremiumUsdg = _sellLongSide(id, terms, qtyRaw, cfg.feeBps, minPremiumUsdg);
    }

    /// @dev Routes the long side to the best bid, verifies the money actually arrived, and pays the
    ///      writer. Split out of `_write` so the escrow path and the payment path can be read, and
    ///      audited, separately.
    function _sellLongSide(
        bytes32 id,
        SeriesTerms memory terms,
        uint256 qtyRaw,
        uint16 feeBps,
        uint256 minPremiumUsdg
    ) internal returns (uint256 netPremiumUsdg) {
        (address buyer, uint256 gross) = bestBid(terms, qtyRaw);
        if (buyer == address(0) || gross == 0) revert NoBid(id);

        uint256 feeUsdg = (gross * feeBps) / BPS;
        netPremiumUsdg = gross - feeUsdg;
        if (netPremiumUsdg < minPremiumUsdg) revert PremiumTooLow(netPremiumUsdg, minPremiumUsdg);

        uint256 before = IERC20(USDG).balanceOf(address(this));
        IOptionBuyer(buyer).executeBuy(id, terms, qtyRaw, gross);
        uint256 received = IERC20(USDG).balanceOf(address(this)) - before;
        // The buyer's return value is not evidence. The balance is.
        if (received < gross) revert BuyerDidNotPay(buyer, gross, received);

        longOf[id][buyer] += qtyRaw;

        if (feeUsdg != 0) USDG.safeTransfer(feeSink, feeUsdg);
        USDG.safeTransfer(msg.sender, netPremiumUsdg);

        emit Written(id, msg.sender, buyer, qtyRaw, gross, feeUsdg);
    }

    // ---------------------------------------------------------------- settlement

    /// @notice Fix a series' settlement price. Permissionless, and callable the instant it expires.
    /// @dev During an issuer halt the oracle refuses to serve a price and this reverts, so
    ///      settlement waits for the halt to lift and takes the first observation after it. The
    ///      price used is the oracle's TWAP rather than a spot print, which is what keeps the
    ///      first caller after a halt from choosing a favourable instant.
    function settle(bytes32 id) public nonReentrant {
        Series storage s = _series[id];
        if (s.asset == address(0)) revert NoSeries(id);
        if (s.settled) revert AlreadySettled(id);
        if (block.timestamp < s.expiry) revert NotExpired(id);

        _sync(id);
        PRICE.poke(s.asset);
        (uint256 value, bool ok, PriceStatus status) = PRICE.tryValueOf(s.asset, RAW_ONE);
        if (!ok) revert PriceUnavailable(status);

        s.settlePriceRaw1e8 = uint128(value);
        s.settledAt = uint64(block.timestamp);
        s.settled = true;
        emit Settled(id, value, block.timestamp);
    }

    /// @notice Take back what the escrow left you.
    function claimShort(bytes32 id) external nonReentrant returns (uint256 returned) {
        Series storage s = _series[id];
        if (s.asset == address(0)) revert NoSeries(id);
        if (!s.settled) revert NotSettled(id);

        uint256 qtyRaw = shortOf[id][msg.sender];
        if (qtyRaw == 0) revert NothingToClaim();
        shortOf[id][msg.sender] = 0;

        uint256 notional = shortNotionalUsd1e8[id][msg.sender];
        shortNotionalUsd1e8[id][msg.sender] = 0;
        REGISTRY.adjustNotional(s.asset, -int256(notional));

        uint256 spot = s.settlePriceRaw1e8;
        uint256 strike = s.strikeRaw1e8;
        if (s.isCall) {
            returned = qtyRaw - _callPayoffRaw(qtyRaw, spot, strike);
            if (returned != 0) s.asset.safeTransfer(msg.sender, returned);
        } else {
            returned = _usdgValue(qtyRaw, strike) - _putPayoffUsdg(qtyRaw, spot, strike);
            if (returned != 0) USDG.safeTransfer(msg.sender, returned);
        }
        emit ShortClaimed(id, msg.sender, qtyRaw, returned);
    }

    /// @notice Collect the long side's intrinsic value.
    function claimLong(bytes32 id) external nonReentrant returns (uint256 payout) {
        Series storage s = _series[id];
        if (s.asset == address(0)) revert NoSeries(id);
        if (!s.settled) revert NotSettled(id);

        uint256 qtyRaw = longOf[id][msg.sender];
        if (qtyRaw == 0) revert NothingToClaim();
        longOf[id][msg.sender] = 0;

        uint256 spot = s.settlePriceRaw1e8;
        uint256 strike = s.strikeRaw1e8;
        if (s.isCall) {
            payout = _callPayoffRaw(qtyRaw, spot, strike);
            if (payout != 0) s.asset.safeTransfer(msg.sender, payout);
        } else {
            payout = _putPayoffUsdg(qtyRaw, spot, strike);
            if (payout != 0) USDG.safeTransfer(msg.sender, payout);
        }
        emit LongClaimed(id, msg.sender, qtyRaw, payout);
    }

    /// @notice Re-derive a series' raw strike against the live multiplier. Permissionless.
    function adjust(bytes32 id) external {
        if (_series[id].asset == address(0)) revert NoSeries(id);
        _sync(id);
    }

    function _sync(bytes32 id) internal {
        Series storage s = _series[id];
        uint256 live = Corporate.multiplierOf(s.asset);
        uint256 previous = s.refMultiplier;
        if (live == previous) return;
        uint256 adjusted = Corporate.adjustStrike(s.strikeRaw1e8, previous, live);
        s.strikeRaw1e8 = uint128(adjusted);
        s.refMultiplier = uint128(live);
        emit SeriesAdjusted(id, previous, live, adjusted);
    }

    // ---------------------------------------------------------------- payoff math

    /// @notice The escrowed raw units a call's long is owed: the fraction of the shares worth
    ///         `S - K`. The writer keeps the rest, which is worth exactly `K`.
    function _callPayoffRaw(uint256 qtyRaw, uint256 spotRaw1e8, uint256 strikeRaw1e8)
        internal
        pure
        returns (uint256)
    {
        if (spotRaw1e8 <= strikeRaw1e8) return 0;
        // Floors, so the sum of every long's claim can never exceed the escrow that backs them.
        return FixedPointMathLib.fullMulDiv(qtyRaw, spotRaw1e8 - strikeRaw1e8, spotRaw1e8);
    }

    /// @notice The escrowed dollars a put's long is owed. The writer keeps dollars worth `S`, the
    ///         same position as having bought the stock at `K`.
    function _putPayoffUsdg(uint256 qtyRaw, uint256 spotRaw1e8, uint256 strikeRaw1e8)
        internal
        view
        returns (uint256)
    {
        if (strikeRaw1e8 <= spotRaw1e8) return 0;
        return _usdgValue(qtyRaw, strikeRaw1e8 - spotRaw1e8);
    }

    function _requireStrikeInBand(uint256 strikeRaw, uint256 spotRaw, uint16 bandBps, bool isCall) internal pure {
        // A covered call is a sell order above the market and a cash-secured put is a buy order
        // below it. Allowing the other side would turn the product into a spot trade wearing an
        // option's clothes, and would break the one sentence the whole thing is sold on.
        if (isCall && strikeRaw < spotRaw) revert BadStrike(strikeRaw, spotRaw);
        if (!isCall && strikeRaw > spotRaw) revert BadStrike(strikeRaw, spotRaw);

        uint256 distance = strikeRaw > spotRaw ? strikeRaw - spotRaw : spotRaw - strikeRaw;
        if (distance * BPS > spotRaw * bandBps) revert BadStrike(strikeRaw, spotRaw);
    }

    // ---------------------------------------------------------------- units

    /// @dev USDG value of `qtyRaw` raw units priced at `price1e8` per raw unit.
    function _usdgValue(uint256 qtyRaw, uint256 price1e8) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(qtyRaw, price1e8 * USDG_SCALE, RAW_ONE * 1e8);
    }

    function _to18(uint256 value1e8) internal pure returns (uint256) {
        return value1e8 * 1e10;
    }

    function _from18(uint256 valueWad) internal pure returns (uint256) {
        return valueWad / 1e10;
    }
}
