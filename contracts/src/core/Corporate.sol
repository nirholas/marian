// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStockToken} from "../interfaces/IStockToken.sol";

/// @notice A corporate action as this chain publishes it: a ratio between two multipliers, and the
///         second at which it lands.
struct Adjustment {
    /// @dev 1e18-scaled `newUIMultiplier / uiMultiplier`. 1e18 means nothing is scheduled.
    uint256 ratioWad;
    /// @dev Unix second the ratio takes effect. Zero when nothing is scheduled.
    uint64 effectiveAt;
}

/// @title Corporate
/// @notice Reads Robinhood Chain's corporate action channel and turns it into a strike adjustment.
///
/// @dev **Why a derivative on this chain cannot ignore the multiplier.** A tokenized equity's raw
///      unit is not a share. `uiMultiplier` is the number of economic shares one raw unit carries,
///      and the issuer moves it for every split, reverse split and dividend. If a call were struck
///      in dollars per raw unit and left alone, a dividend would raise the dollar value of a raw
///      unit and drag the option in the money with no move in the stock at all. The writer would be
///      assigned on a payout they were entitled to keep.
///
///      The fix is the same one the OCC applies by memo on a listed market, done here in code and
///      in advance: when the multiplier moves by ratio `r`, multiply the raw strike by `r`. The
///      escrowed raw units never move, the option's moneyness in economic terms never moves, and
///      the accrual stays with the shareholder who earned it. Because the ratio is scaled rather
///      than the contract size, this is correct in both directions: a reverse split (`r < 1`) is
///      handled by the same line as a dividend (`r > 1`), and the escrow can never be left short.
///
///      **What makes this different from every other chain.** `newUIMultiplier`/`effectiveAt`
///      publish the next value *before* it is live. A series can therefore be adjusted, and a
///      writer warned, ahead of the action rather than after it. `pendingOf` is that warning.
library Corporate {
    /// @notice 1e18. A ratio of exactly this means "no adjustment".
    uint256 internal constant ONE = 1e18;

    /// @notice The multiplier in force right now.
    function multiplierOf(address token) internal view returns (uint256 m) {
        m = IStockToken(token).uiMultiplier();
        // A token that reports a zero multiplier would silently zero every strike derived from it.
        // Treat it as unusable rather than as 1e18: the caller's `require` is the honest place to
        // stop, not a default that keeps trading against a broken reading.
        require(m != 0, "Corporate: zero multiplier");
    }

    /// @notice The scheduled next multiplier, if the issuer has published one that has not landed.
    /// @dev Returns `ratioWad == ONE` when nothing is scheduled, which includes the common case on
    ///      this chain where `newUIMultiplier() == uiMultiplier()` and `effectiveAt()` is in the
    ///      past because it records when the *current* value took over.
    function pendingOf(address token) internal view returns (Adjustment memory adj) {
        IStockToken s = IStockToken(token);
        uint256 live = s.uiMultiplier();
        uint256 next = s.newUIMultiplier();
        uint256 at = s.effectiveAt();
        // `type(uint64).max` is the year 584942099536. An `effectiveAt` beyond it is a broken
        // reading rather than a schedule, and truncating it would silently move an adjustment into
        // the past, so the schedule is dropped instead of narrowed.
        if (live == 0 || next == 0 || next == live || at <= block.timestamp || at > type(uint64).max) {
            return Adjustment({ratioWad: ONE, effectiveAt: 0});
        }
        adj = Adjustment({ratioWad: (next * ONE) / live, effectiveAt: uint64(at)});
    }

    /// @notice Apply a multiplier move to a raw-denominated strike.
    /// @param strikeRaw1e8 Dollars per raw unit, at 1e8.
    /// @param fromMultiplier The multiplier the strike was last adjusted against.
    /// @param toMultiplier The multiplier in force now.
    function adjustStrike(uint256 strikeRaw1e8, uint256 fromMultiplier, uint256 toMultiplier)
        internal
        pure
        returns (uint256)
    {
        if (fromMultiplier == toMultiplier || fromMultiplier == 0) return strikeRaw1e8;
        return (strikeRaw1e8 * toMultiplier) / fromMultiplier;
    }

    /// @notice Convert a strike quoted per economic share into the raw-unit strike actually stored.
    /// @dev This is the whole reason a user never sees a multiplier. They name "$180 a share";
    ///      the protocol stores dollars per raw unit and re-derives the user's number on the way
    ///      out, so a corporate action changes the stored value and never the promise.
    function strikePerShareToRaw(uint256 strikePerShare1e8, uint256 multiplier) internal pure returns (uint256) {
        return (strikePerShare1e8 * multiplier) / ONE;
    }

    /// @notice The inverse of `strikePerShareToRaw`, for display.
    function strikeRawToPerShare(uint256 strikeRaw1e8, uint256 multiplier) internal pure returns (uint256) {
        require(multiplier != 0, "Corporate: zero multiplier");
        return (strikeRaw1e8 * ONE) / multiplier;
    }

    /// @notice Economic shares represented by `rawAmount` raw units at the live multiplier.
    function sharesOf(address token, uint256 rawAmount) internal view returns (uint256) {
        return (rawAmount * multiplierOf(token)) / ONE;
    }
}
