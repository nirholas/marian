// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPriceSource, PriceStatus} from "../interfaces/IPriceSource.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {Corporate} from "./Corporate.sol";

/// @notice How one equity is priced.
struct FeedConfig {
    /// @dev The deepest USDG pool for this equity.
    address pool;
    /// @dev True when the equity is the pool's token0. Getting this wrong inverts every price, so
    ///      it is stored rather than guessed.
    bool assetIsToken0;
    /// @dev TWAP window in seconds.
    uint32 window;
    /// @dev Largest tolerated gap between the TWAP and the pool's current tick, in basis points.
    uint16 maxDeviationBps;
    /// @dev How long before and after a scheduled corporate action the feed refuses to serve.
    uint32 adjustmentBlackout;
    bool enabled;
}

/// @title EquityOracle
/// @notice A halt-aware price for a Robinhood tokenized equity, derived from the only liquid
///         venue that exists for it on this chain.
///
/// @dev **There is no price oracle on Robinhood Chain.** No Chainlink, no Pyth, no first-party
///      feed. There is a Uniswap v3 deployment with real depth in USDG pairs and an issuer that
///      publishes halt flags. This contract is what those two facts add up to.
///
///      **What it refuses to do is the point.** A feed for an ordinary ERC-20 has one failure mode,
///      a stale or manipulated price. An equity on this chain has four more, and each of them is a
///      distinct `PriceStatus` here rather than a number that quietly keeps being served:
///
///      * `TokenPaused`: the issuer froze transfers. Nothing can be seized, delivered or settled,
///        so serving a price would let a protocol take an action it cannot complete.
///      * `IssuerOraclePaused`: the issuer disavowed the price while transfers still work. The
///        market may keep trading; this contract will not tell anyone what it thinks that means.
///      * `MultiplierTransition`: a corporate action is scheduled inside the blackout window. The
///        pool prices raw units and the multiplier is about to change what a raw unit is, so the
///        TWAP spans two different definitions of the asset and means nothing.
///      * `TwapDeviation`: the window average and the current tick disagree by more than the
///        configured band, which is what a manipulation attempt looks like from inside the pool.
///
///      **Why a TWAP rather than the spot tick.** Measured on this chain, moving the SPY/USDG pool
///      is a cliff rather than a slope: a large enough single swap takes the price from unchanged
///      to collapsed with very little in between. A window average makes that attack cost the
///      attacker the whole window rather than one block, and the deviation guard turns the attempt
///      into a refusal instead of a bad print.
contract EquityOracle is IPriceSource, Ownable {
    using FixedPointMathLib for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAW_ONE = 1e18;
    /// @dev 1.0001, the tick base, in wad.
    int256 internal constant TICK_BASE_WAD = 1000100000000000000;

    mapping(address => FeedConfig) private _feeds;
    address[] private _assets;
    mapping(address => bool) private _known;

    /// @dev The stable side of every pool. Six decimals on this chain.
    address public immutable USDG;
    uint256 public immutable USDG_SCALE;

    event FeedConfigured(address indexed asset, FeedConfig config);

    error NotUsable(address asset, PriceStatus status);
    error BadFeed(string field);

    constructor(address owner_, address usdg, uint8 usdgDecimals) {
        _initializeOwner(owner_);
        USDG = usdg;
        USDG_SCALE = 10 ** usdgDecimals;
    }

    function configure(address asset, FeedConfig calldata config) external onlyOwner {
        if (config.pool == address(0)) revert BadFeed("pool");
        if (config.window < 300 || config.window > 2 hours) revert BadFeed("window");
        if (config.maxDeviationBps == 0 || config.maxDeviationBps > 5_000) revert BadFeed("maxDeviationBps");
        if (config.adjustmentBlackout > 7 days) revert BadFeed("adjustmentBlackout");

        IUniswapV3Pool pool = IUniswapV3Pool(config.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        // The pool must actually be this equity against USDG. A misconfigured pair is the one
        // mistake here that produces a plausible-looking wrong number rather than a revert.
        if (config.assetIsToken0) {
            if (token0 != asset || token1 != USDG) revert BadFeed("pair");
        } else {
            if (token1 != asset || token0 != USDG) revert BadFeed("pair");
        }
        (,,, uint16 cardinality,,,) = pool.slot0();
        // A pool that stores one observation cannot answer `observe` over any window at all.
        if (cardinality < 2) revert BadFeed("cardinality");

        _feeds[asset] = config;
        if (!_known[asset]) {
            _known[asset] = true;
            _assets.push(asset);
        }
        emit FeedConfigured(asset, config);
    }

    function feedOf(address asset) external view returns (FeedConfig memory) {
        return _feeds[asset];
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    /// @inheritdoc IPriceSource
    function valueOf(address asset, uint256 rawAmount) external view returns (uint256) {
        (uint256 value, bool ok, PriceStatus status) = tryValueOf(asset, rawAmount);
        if (!ok) revert NotUsable(asset, status);
        return value;
    }

    /// @inheritdoc IPriceSource
    function tryValueOf(address asset, uint256 rawAmount)
        public
        view
        returns (uint256 usd1e8, bool ok, PriceStatus status)
    {
        FeedConfig memory feed = _feeds[asset];
        if (!feed.enabled || feed.pool == address(0)) return (0, false, PriceStatus.NoConfig);

        IStockToken stock = IStockToken(asset);
        if (stock.paused()) return (0, false, PriceStatus.TokenPaused);
        if (stock.oraclePaused()) return (0, false, PriceStatus.IssuerOraclePaused);

        // A scheduled multiplier change inside the blackout makes the window span two different
        // definitions of a raw unit. Refusing is the only honest answer.
        if (feed.adjustmentBlackout != 0) {
            uint256 at = stock.effectiveAt();
            if (at != 0 && stock.newUIMultiplier() != stock.uiMultiplier()) {
                uint256 blackout = feed.adjustmentBlackout;
                if (block.timestamp + blackout >= at && block.timestamp <= at + blackout) {
                    return (0, false, PriceStatus.MultiplierTransition);
                }
            }
        }

        (int24 twapTick, bool twapOk) = _twapTick(feed);
        if (!twapOk) return (0, false, PriceStatus.TwapUnavailable);

        (, int24 spotTick,,,,,) = IUniswapV3Pool(feed.pool).slot0();
        if (!_withinDeviation(twapTick, spotTick, feed.maxDeviationBps)) {
            return (0, false, PriceStatus.TwapDeviation);
        }

        uint256 pricePerToken1e8 = _priceFromTick(twapTick, feed.assetIsToken0);
        if (pricePerToken1e8 == 0) return (0, false, PriceStatus.NoQuote);

        usd1e8 = FixedPointMathLib.fullMulDiv(rawAmount, pricePerToken1e8, RAW_ONE);
        return (usd1e8, true, PriceStatus.OK);
    }

    /// @inheritdoc IPriceSource
    /// @dev Nothing to checkpoint: every input is derivable in a view. Kept because the interface
    ///      exists for feeds that are not, and a product should not have to know which kind it has.
    function poke(address asset) external view {
        _feeds[asset];
    }

    /// @notice The arithmetic-mean tick over the feed's window.
    function _twapTick(FeedConfig memory feed) internal view returns (int24 tick, bool ok) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = feed.window;
        ago[1] = 0;
        try IUniswapV3Pool(feed.pool).observe(ago) returns (int56[] memory cumulatives, uint160[] memory) {
            int56 delta = cumulatives[1] - cumulatives[0];
            int56 average = delta / int56(uint56(feed.window));
            // Uniswap floors the division toward negative infinity for consistency with its own
            // library; reproducing that here keeps this tick identical to the one every other
            // consumer of the pool computes.
            if (delta < 0 && (delta % int56(uint56(feed.window)) != 0)) average--;
            return (int24(average), true);
        } catch {
            return (0, false);
        }
    }

    function _withinDeviation(int24 twapTick, int24 spotTick, uint16 maxDeviationBps) internal pure returns (bool) {
        int256 gap = int256(twapTick) - int256(spotTick);
        if (gap < 0) gap = -gap;
        // One tick is one basis point of price by construction (1.0001^1), so a tick gap and a
        // basis-point gap are the same number to well within the tolerance being applied.
        return uint256(gap) <= uint256(maxDeviationBps);
    }

    /// @notice The dollar price of one whole equity token, at 1e8, from a tick.
    ///
    /// @dev The unit is worth stating precisely because it is the easiest thing in this file to get
    ///      wrong by six or twelve orders of magnitude and still return a plausible number. A pool
    ///      tick encodes `1.0001^tick` = raw token1 per raw token0. Equities here are 18 decimals
    ///      and USDG is 6, so for NVDA at $180 that raw ratio is 5.56e9 (tick 224392) and the
    ///      wad-scaled inverse is exactly 1.8e8, which becomes 1.8e10 at 1e8 dollars. Every
    ///      intermediate in this function was checked against those figures.
    ///
    ///      `powWad` rather than Uniswap's `TickMath`: at these magnitudes its relative error is
    ///      around 2e-13, which is a hundred thousand times finer than the deviation band the
    ///      caller is about to apply, and it replaces several hundred lines of assembly.
    function _priceFromTick(int24 tick, bool assetIsToken0) internal view returns (uint256) {
        int256 ratioWad = FixedPointMathLib.powWad(TICK_BASE_WAD, int256(tick) * 1e18);
        if (ratioWad <= 0) return 0;
        uint256 ratio = uint256(ratioWad);

        // `ratio` is token1 per token0 in wad, before decimals. Convert to USDG per raw equity unit
        // and then to 1e8 dollars.
        uint256 usdgPerRaw;
        if (assetIsToken0) {
            usdgPerRaw = ratio;
        } else {
            if (ratio == 0) return 0;
            usdgPerRaw = FixedPointMathLib.divWad(1e18, ratio);
        }
        // `usdgPerRaw` is the wad of "raw USDG per raw equity unit". One whole equity is 1e18 raw
        // units, which cancels the wad, leaving raw USDG per token; dividing by USDG_SCALE turns
        // those into dollars and 1e8 puts them in the protocol's price unit.
        return FixedPointMathLib.fullMulDiv(usdgPerRaw, 1e8, USDG_SCALE);
    }
}
