// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IOptionBuyer, SeriesTerms} from "./IOptionBuyer.sol";
import {ISwapVenue} from "./ISwapVenue.sol";
import {OptionMath} from "./OptionMath.sol";
import {VolSurface} from "./VolSurface.sol";
import {PaidOrders, Series} from "./PaidOrders.sol";
import {AssetRegistry, AssetConfig} from "../core/AssetRegistry.sol";
import {Corporate} from "../core/Corporate.sol";
import {IPriceSource, PriceStatus} from "../interfaces/IPriceSource.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @notice One long option position the vault holds.
struct Position {
    SeriesTerms terms;
    uint256 qtyRaw;
    uint256 premiumPaidUsdg;
}

/// @title UnderwriterVault
/// @notice The bid that is always there.
///
/// @dev **Why the vault exists.** A writer who presses "get paid to wait" and is shown "no bids"
///      does not come back. The vault's job is to make that screen impossible: it quotes every
///      enabled series, every second, within its risk limits, so the product always works even
///      when no professional desk happens to be watching. It is the floor under the market. It is
///      not supposed to be the market, and `PaidOrders` routes to whoever bids highest precisely
///      so that it gets outbid.
///
///      **Why it can be profitable while being long options.** The vault buys what retail writes,
///      which makes it long volatility, and the long-volatility side of an equity option is the
///      side that historically pays the variance risk premium rather than earning it. Bidding at
///      the surface's fair vol would therefore lose money on average, slowly and invisibly, which
///      is exactly the kind of failure a vault full of other people's capital must not have.
///
///      So the vault does not bid fair value. It bids a vol below the surface (`volHaircutBps`)
///      and then takes a further cut of the premium (`edgeBps`), which is what a dealer buying
///      retail flow has always done. The writer still gets a real, instant, competitive price; the
///      vault's expectancy under its own model is positive rather than negative; and the gap
///      between the two is visible on chain rather than buried in a spread.
///
///      **What bounds the damage when the model is wrong.** A long option cannot lose more than
///      its premium, so the vault's worst case on any single trade is known at the moment it
///      trades. The limits below cap how much of that worst case can be live at once: per trade,
///      in total, and as a floor on the cash held against redemptions.
contract UnderwriterVault is IOptionBuyer, Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAW_ONE = 1e18;
    /// @dev Bounds the NAV loop. NAV is read on every deposit, withdrawal and quote.
    uint256 public constant MAX_OPEN_POSITIONS = 64;

    PaidOrders public immutable BOOK;
    VolSurface public immutable VOL;
    IPriceSource public immutable PRICE;
    AssetRegistry public immutable REGISTRY;
    address public immutable USDG;
    uint256 public immutable USDG_SCALE;

    ISwapVenue public swapVenue;

    /// @dev Vol haircut applied to the surface before the vault will pay for it.
    uint256 public volHaircutBps = 2_000;
    /// @dev Further cut taken from the modelled premium.
    uint256 public edgeBps = 500;
    /// @dev Largest premium the vault will pay in one trade.
    uint256 public maxPremiumPerTradeUsdg;
    /// @dev Largest total premium that may be live in unsettled positions at once.
    uint256 public maxOpenPremiumUsdg;
    /// @dev Share of NAV that must stay in cash, so LPs are not gated behind option expiries.
    uint256 public minCashBps = 3_000;

    uint256 public openPremiumUsdg;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    bytes32[] private _openIds;
    mapping(bytes32 => uint256) private _openIndexPlusOne;
    mapping(bytes32 => Position) private _positions;

    mapping(address => bool) public isKeeper;

    event Deposited(address indexed lp, uint256 amountUsdg, uint256 shares);
    event Withdrawn(address indexed lp, uint256 shares, uint256 amountUsdg);
    event Bought(bytes32 indexed id, uint256 qtyRaw, uint256 premiumUsdg);
    event Harvested(bytes32 indexed id, uint256 payout, uint256 usdgRecovered);
    event LimitsSet(uint256 volHaircutBps, uint256 edgeBps, uint256 maxPerTrade, uint256 maxOpen, uint256 minCashBps);
    event KeeperSet(address indexed keeper, bool allowed);
    event SwapVenueSet(address indexed venue);

    error OnlyBook();
    error OnlyKeeper();
    error LimitBreached();
    error InsufficientFreeCash(uint256 requested, uint256 available);
    error PositionNotSettled(bytes32 id);
    error NoPosition(bytes32 id);
    error TooManyPositions();
    error NoSwapVenue();

    constructor(address owner_, address book, address registry, address vol, address price, address usdg) {
        _initializeOwner(owner_);
        BOOK = PaidOrders(book);
        REGISTRY = AssetRegistry(registry);
        VOL = VolSurface(vol);
        PRICE = IPriceSource(price);
        USDG = usdg;
        USDG_SCALE = 10 ** IERC20(usdg).decimals();
    }

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert OnlyKeeper();
        _;
    }

    // ---------------------------------------------------------------- admin

    function setLimits(uint256 haircutBps, uint256 edge, uint256 perTrade, uint256 openCap, uint256 cashBps)
        external
        onlyOwner
    {
        require(haircutBps < BPS && edge < BPS && cashBps <= BPS, "Vault: bps out of range");
        volHaircutBps = haircutBps;
        edgeBps = edge;
        maxPremiumPerTradeUsdg = perTrade;
        maxOpenPremiumUsdg = openCap;
        minCashBps = cashBps;
        emit LimitsSet(haircutBps, edge, perTrade, openCap, cashBps);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setSwapVenue(address venue) external onlyOwner {
        swapVenue = ISwapVenue(venue);
        emit SwapVenueSet(venue);
    }

    // ---------------------------------------------------------------- LP

    /// @notice Total value of the vault, in USDG: cash plus every open position marked to model.
    function nav() public view returns (uint256 total) {
        total = IERC20(USDG).balanceOf(address(this));
        uint256 n = _openIds.length;
        for (uint256 i; i < n; ++i) {
            total += _markPosition(_openIds[i]);
        }
    }

    /// @notice Cash the vault may spend without breaching its cash floor.
    function freeCash() public view returns (uint256) {
        uint256 cash = IERC20(USDG).balanceOf(address(this));
        uint256 floorCash = (nav() * minCashBps) / BPS;
        return cash > floorCash ? cash - floorCash : 0;
    }

    function deposit(uint256 amountUsdg) external nonReentrant returns (uint256 shares) {
        require(amountUsdg != 0, "Vault: zero deposit");
        uint256 navBefore = nav();
        USDG.safeTransferFrom(msg.sender, address(this), amountUsdg);
        shares = totalShares == 0 ? amountUsdg : FixedPointMathLib.fullMulDiv(amountUsdg, totalShares, navBefore);
        require(shares != 0, "Vault: zero shares");
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        emit Deposited(msg.sender, amountUsdg, shares);
    }

    /// @notice Redeem shares for cash.
    /// @dev Bounded by the cash actually held, not by NAV. A vault that promised instant
    ///      redemption of capital sitting inside an unexpired option would be promising something
    ///      it cannot do; the error says exactly how much is available so the caller can split the
    ///      redemption rather than guess.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 amountUsdg) {
        require(shares != 0 && shares <= sharesOf[msg.sender], "Vault: bad share amount");
        amountUsdg = FixedPointMathLib.fullMulDiv(shares, nav(), totalShares);
        uint256 cash = IERC20(USDG).balanceOf(address(this));
        if (amountUsdg > cash) revert InsufficientFreeCash(amountUsdg, cash);

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        USDG.safeTransfer(msg.sender, amountUsdg);
        emit Withdrawn(msg.sender, shares, amountUsdg);
    }

    // ---------------------------------------------------------------- quoting

    /// @inheritdoc IOptionBuyer
    function quoteBuy(bytes32, SeriesTerms calldata terms, uint256 qtyRaw)
        external
        view
        returns (uint256 premiumUsdg)
    {
        (uint256 bid, bool ok) = _bid(terms, qtyRaw);
        if (!ok) return 0;
        return bid;
    }

    /// @dev Every reason a quote is unavailable returns `false` rather than reverting, because the
    ///      router treats a reverting buyer as broken and this contract being unable to bid on one
    ///      series is not the same thing as it being broken.
    function _bid(SeriesTerms calldata terms, uint256 qtyRaw) internal view returns (uint256 premiumUsdg, bool ok) {
        if (qtyRaw == 0 || terms.expiry <= block.timestamp) return (0, false);
        if (_openIds.length >= MAX_OPEN_POSITIONS) return (0, false);

        AssetConfig memory cfg = REGISTRY.configOf(terms.asset);
        if (!cfg.enabled) return (0, false);

        (uint256 spotRaw, bool priceOk,) = PRICE.tryValueOf(terms.asset, RAW_ONE);
        if (!priceOk || spotRaw == 0) return (0, false);

        uint256 multiplier;
        try IERC20(terms.asset).totalSupply() returns (uint256) {
            multiplier = Corporate.multiplierOf(terms.asset);
        } catch {
            return (0, false);
        }
        uint256 strikeRaw = Corporate.strikePerShareToRaw(terms.strikePerShare1e8, multiplier);
        if (strikeRaw == 0) return (0, false);

        uint256 spotWad = spotRaw * 1e10;
        uint256 strikeWad = strikeRaw * 1e10;
        (uint256 surfaceVol, bool volOk) = VOL.tryVolFor(terms.asset, spotWad, strikeWad);
        if (!volOk) return (0, false);

        uint256 bidVol = (surfaceVol * (BPS - volHaircutBps)) / BPS;
        uint256 floorVol = VOL.minVolWad();
        if (bidVol < floorVol) bidVol = floorVol;

        uint256 tau = OptionMath.yearsOf(terms.expiry - block.timestamp);
        (uint256 call, uint256 put) = OptionMath.callPut(spotWad, strikeWad, tau, bidVol, BOOK.rateWad());
        uint256 perRawWad = terms.isCall ? call : put;
        if (perRawWad == 0) return (0, false);

        premiumUsdg = _usdgValue(qtyRaw, perRawWad / 1e10);
        premiumUsdg = (premiumUsdg * (BPS - edgeBps)) / BPS;
        if (premiumUsdg == 0) return (0, false);

        if (maxPremiumPerTradeUsdg != 0 && premiumUsdg > maxPremiumPerTradeUsdg) return (0, false);
        if (maxOpenPremiumUsdg != 0 && openPremiumUsdg + premiumUsdg > maxOpenPremiumUsdg) return (0, false);
        if (premiumUsdg > freeCash()) return (0, false);

        return (premiumUsdg, true);
    }

    /// @inheritdoc IOptionBuyer
    function executeBuy(bytes32 id, SeriesTerms calldata terms, uint256 qtyRaw, uint256 premiumUsdg)
        external
        nonReentrant
    {
        if (msg.sender != address(BOOK)) revert OnlyBook();
        (uint256 bid, bool ok) = _bid(terms, qtyRaw);
        // The router asks for the price this contract quoted. Re-deriving it here means a router
        // bug, or a router replaced by a malicious one, cannot make the vault overpay: the limit is
        // enforced by the contract holding the money, not by the one asking for it.
        if (!ok || premiumUsdg > bid) revert LimitBreached();

        Position storage p = _positions[id];
        if (p.qtyRaw == 0) {
            if (_openIds.length >= MAX_OPEN_POSITIONS) revert TooManyPositions();
            p.terms = terms;
            _openIds.push(id);
            _openIndexPlusOne[id] = _openIds.length;
        }
        p.qtyRaw += qtyRaw;
        p.premiumPaidUsdg += premiumUsdg;
        openPremiumUsdg += premiumUsdg;

        USDG.safeTransfer(address(BOOK), premiumUsdg);
        emit Bought(id, qtyRaw, premiumUsdg);
    }

    // ---------------------------------------------------------------- harvesting

    /// @notice Collect a settled position and return it to cash in one transaction.
    /// @dev Claim and sale are deliberately atomic. A vault that claimed shares in one transaction
    ///      and sold them in another would carry unhedged single-name equity between the two, which
    ///      is a risk its LPs were never quoted and its model never priced.
    function harvest(bytes32 id, uint256 minUsdgOut) external onlyKeeper nonReentrant returns (uint256 recovered) {
        Position memory p = _positions[id];
        if (p.qtyRaw == 0) revert NoPosition(id);
        Series memory s = BOOK.seriesOf(id);
        if (!s.settled) revert PositionNotSettled(id);

        uint256 payout = BOOK.claimLong(id);
        if (p.terms.isCall && payout != 0) {
            if (address(swapVenue) == address(0)) revert NoSwapVenue();
            p.terms.asset.safeApprove(address(swapVenue), payout);
            recovered = swapVenue.sellForUsdg(p.terms.asset, payout, minUsdgOut, address(this));
            p.terms.asset.safeApprove(address(swapVenue), 0);
        } else {
            recovered = payout;
        }

        openPremiumUsdg -= p.premiumPaidUsdg;
        _removeOpen(id);
        delete _positions[id];
        emit Harvested(id, payout, recovered);
    }

    function positionOf(bytes32 id) external view returns (Position memory) {
        return _positions[id];
    }

    function openPositions() external view returns (bytes32[] memory) {
        return _openIds;
    }

    /// @dev Mark one open position to model, in USDG. A settled position marks at its realised
    ///      intrinsic value instead, because after settlement there is nothing left to model.
    function _markPosition(bytes32 id) internal view returns (uint256) {
        Position storage p = _positions[id];
        if (p.qtyRaw == 0) return 0;
        Series memory s = BOOK.seriesOf(id);

        if (s.settled) {
            uint256 spot = s.settlePriceRaw1e8;
            uint256 strike = s.strikeRaw1e8;
            if (p.terms.isCall) {
                if (spot <= strike) return 0;
                uint256 sharesOwed = FixedPointMathLib.fullMulDiv(p.qtyRaw, spot - strike, spot);
                return _usdgValue(sharesOwed, spot);
            }
            if (strike <= spot) return 0;
            return _usdgValue(p.qtyRaw, strike - spot);
        }

        (uint256 spotRaw, bool priceOk,) = PRICE.tryValueOf(p.terms.asset, RAW_ONE);
        // A halted or unpriced asset marks at zero rather than at a stale price. It understates
        // NAV, which makes a depositor pay slightly too much and a redeemer receive slightly too
        // little... the conservative direction, and the only one that cannot be farmed by choosing
        // when to transact.
        if (!priceOk || spotRaw == 0) return 0;

        uint256 strikeRawNow = s.strikeRaw1e8;
        if (strikeRawNow == 0) return 0;
        uint256 spotWad = spotRaw * 1e10;
        uint256 strikeWad = strikeRawNow * 1e10;
        (uint256 volWad, bool volOk) = VOL.tryVolFor(p.terms.asset, spotWad, strikeWad);
        if (!volOk) return 0;

        uint256 tau = s.expiry > block.timestamp ? OptionMath.yearsOf(s.expiry - block.timestamp) : 0;
        (uint256 call, uint256 put) = OptionMath.callPut(spotWad, strikeWad, tau, volWad, BOOK.rateWad());
        return _usdgValue(p.qtyRaw, (p.terms.isCall ? call : put) / 1e10);
    }

    function _removeOpen(bytes32 id) internal {
        uint256 indexPlusOne = _openIndexPlusOne[id];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 last = _openIds.length - 1;
        if (index != last) {
            bytes32 moved = _openIds[last];
            _openIds[index] = moved;
            _openIndexPlusOne[moved] = index + 1;
        }
        _openIds.pop();
        delete _openIndexPlusOne[id];
    }

    function _usdgValue(uint256 qtyRaw, uint256 price1e8) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(qtyRaw, price1e8 * USDG_SCALE, RAW_ONE * 1e8);
    }
}
