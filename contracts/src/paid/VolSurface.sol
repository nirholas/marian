// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {OptionMath} from "./OptionMath.sol";

/// @notice One asset's volatility, as reporters publish it.
struct VolQuote {
    /// @dev At-the-money annualised vol, wad. 0.45e18 is 45%.
    uint128 atmVolWad;
    /// @dev Slope of vol against log-moneyness, wad. Negative is the ordinary equity skew: puts
    ///      below spot trade at a higher vol than calls above it.
    int128 skewWad;
    /// @dev When this was last written.
    uint64 updatedAt;
}

/// @title VolSurface
/// @notice The only judgement call in the protocol, kept behind one contract with hard bounds.
///
/// @dev **What this is and is not.** Everything else in Marian is arithmetic on facts the chain
///      already publishes: a balance, a multiplier, a pause flag, a pool TWAP. Volatility is not
///      one of those. It is a forecast, it is what the premium is actually made of, and it is the
///      one input a dishonest or compromised reporter could use to make a user write a call for
///      nothing.
///
///      So the surface is bounded rather than trusted. A reporter can move vol within
///      `maxMoveBps` of its previous value per update and no further, cannot leave
///      `[minVolWad, maxVolWad]`, and cannot make a quote at all once its own is `maxAge` old.
///      A stale surface fails closed: the venue stops quoting rather than quoting from a number
///      nobody has stood behind recently. The worst a captured reporter achieves is a bounded
///      drift over many blocks, in public, against a floor.
///
///      **The shape.** `vol(K) = atm + skew * ln(K/S)`, clamped. Two parameters, because a fitted
///      surface with more of them would need a fitter, and a fitter that runs on chain is a loop
///      with an unbounded gas cost sitting in a quote path. The equity skew this reproduces is the
///      part that matters for a covered call: the call being written is above spot, where the skew
///      makes the premium smaller, and rounding that to a flat surface would systematically
///      overpay writers out of the vault's capital.
contract VolSurface is Ownable {
    uint256 internal constant BPS = 10_000;

    mapping(address => VolQuote) private _quotes;
    mapping(address => bool) public isReporter;

    uint256 public minVolWad = 0.05e18;
    uint256 public maxVolWad = 3e18;
    /// @dev Largest relative move a single update may make to ATM vol.
    uint256 public maxMoveBps = 2_500;
    /// @dev A quote older than this cannot be used to price anything.
    uint64 public maxAge = 6 hours;

    event ReporterSet(address indexed reporter, bool allowed);
    event QuotePosted(address indexed asset, uint256 atmVolWad, int256 skewWad, address indexed reporter);
    event BoundsSet(uint256 minVolWad, uint256 maxVolWad, uint256 maxMoveBps, uint64 maxAge);

    error NotReporter();
    error VolOutOfBounds(uint256 atmVolWad);
    error VolMovedTooFar(uint256 fromWad, uint256 toWad);
    error NoQuote(address asset);
    error QuoteStale(address asset, uint64 updatedAt);

    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    function setReporter(address reporter, bool allowed) external onlyOwner {
        isReporter[reporter] = allowed;
        emit ReporterSet(reporter, allowed);
    }

    function setBounds(uint256 minVol, uint256 maxVol, uint256 moveBps, uint64 age) external onlyOwner {
        require(minVol != 0 && minVol < maxVol, "VolSurface: bad vol bounds");
        require(moveBps != 0 && moveBps <= BPS, "VolSurface: bad move bound");
        require(age >= 5 minutes, "VolSurface: age too short");
        minVolWad = minVol;
        maxVolWad = maxVol;
        maxMoveBps = moveBps;
        maxAge = age;
        emit BoundsSet(minVol, maxVol, moveBps, age);
    }

    /// @notice Publish a new ATM vol and skew for one asset.
    function post(address asset, uint256 atmVolWad, int256 skewWad) external {
        if (!isReporter[msg.sender]) revert NotReporter();
        if (atmVolWad < minVolWad || atmVolWad > maxVolWad) revert VolOutOfBounds(atmVolWad);
        // A skew steeper than this would let a reporter drive the wing vol to a bound while leaving
        // ATM untouched, which is the same attack with an extra step.
        require(skewWad >= -2e18 && skewWad <= 2e18, "VolSurface: skew out of bounds");

        VolQuote memory previous = _quotes[asset];
        if (previous.updatedAt != 0) {
            uint256 from = previous.atmVolWad;
            uint256 delta = atmVolWad > from ? atmVolWad - from : from - atmVolWad;
            if (delta * BPS > from * maxMoveBps) revert VolMovedTooFar(from, atmVolWad);
        }

        _quotes[asset] =
            VolQuote({atmVolWad: uint128(atmVolWad), skewWad: int128(skewWad), updatedAt: uint64(block.timestamp)});
        emit QuotePosted(asset, atmVolWad, skewWad, msg.sender);
    }

    function quoteOf(address asset) external view returns (VolQuote memory) {
        return _quotes[asset];
    }

    /// @notice Volatility for one strike, or a reason it cannot be served.
    /// @param spot Underlying price per raw unit, wad.
    /// @param strike Strike per raw unit, wad.
    function tryVolFor(address asset, uint256 spot, uint256 strike)
        public
        view
        returns (uint256 volWad, bool ok)
    {
        VolQuote memory q = _quotes[asset];
        if (q.updatedAt == 0) return (0, false);
        if (block.timestamp > uint256(q.updatedAt) + maxAge) return (0, false);
        if (spot == 0 || strike == 0) return (0, false);

        int256 logMoneyness = FixedPointMathLib.lnWad(int256(FixedPointMathLib.divWad(strike, spot)));
        int256 adjusted = int256(uint256(q.atmVolWad)) + OptionMath.smul(int256(q.skewWad), logMoneyness);

        uint256 lower = minVolWad;
        uint256 upper = maxVolWad;
        if (adjusted < int256(lower)) return (lower, true);
        if (adjusted > int256(upper)) return (upper, true);
        return (uint256(adjusted), true);
    }

    /// @notice `tryVolFor` with the failure turned into a revert, for callers that cannot proceed.
    function volFor(address asset, uint256 spot, uint256 strike) external view returns (uint256) {
        (uint256 volWad, bool ok) = tryVolFor(asset, spot, strike);
        if (!ok) {
            VolQuote memory q = _quotes[asset];
            if (q.updatedAt == 0) revert NoQuote(asset);
            revert QuoteStale(asset, q.updatedAt);
        }
        return volWad;
    }
}
