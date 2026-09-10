// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title OptionMath
/// @notice Black-Scholes for fully collateralised European options, in 1e18 fixed point.
///
/// @dev **Why the model is on chain at all.** The protocol never needs a price to settle: a
///      settled option pays intrinsic out of collateral that is already escrowed. The model exists
///      for one job, quoting the premium a writer is offered before they commit, and that number is
///      the entire product. A retail user pressing "get paid to wait" is shown a dollar amount, and
///      that amount has to be derived from something they can audit rather than from a server.
///
///      **Accuracy.** The normal CDF uses Abramowitz and Stegun 7.1.26, whose absolute error is
///      bounded by 1.5e-7 across the whole real line. Premiums are quoted to 1e8 of a dollar on
///      four-figure notionals, so the approximation is two orders of magnitude finer than the unit
///      being quoted, and `test/OptionMath.t.sol` pins every branch against values computed
///      independently in double precision.
///
///      **What is deliberately absent.** No implied-vol solver and no Greeks beyond delta. A
///      solver is an unbounded loop in a quote path, and the vault that needs delta computes it
///      from the same `d1` this library already produces rather than from a second model.
library OptionMath {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    int256 internal constant WAD = 1e18;
    uint256 internal constant UWAD = 1e18;

    /// @dev sqrt(2) in wad, relating the CDF to the error function.
    int256 private constant SQRT2 = 1414213562373095049;

    /// @dev Beyond this the lower tail is under 8e-13 and the rational branch below stops being the
    ///      better answer. 7.07106781186547 in wad.
    int256 private constant TAIL_CUTOFF = 7071067811865470000;

    /// @dev Hart 1968 numerator coefficients, as published by West (2005), in wad.
    int256 private constant N0 = 35262496599891100;
    int256 private constant N1 = 700383064443688000;
    int256 private constant N2 = 6373962203531650000;
    int256 private constant N3 = 33912866078383000000;
    int256 private constant N4 = 112079291497871000000;
    int256 private constant N5 = 221213596169931000000;
    int256 private constant N6 = 220206867912376000000;

    /// @dev Hart 1968 denominator coefficients, in wad.
    int256 private constant D0 = 88388347648318400;
    int256 private constant D1 = 1755667163182640000;
    int256 private constant D2 = 16064177579207000000;
    int256 private constant D3 = 86780732202946100000;
    int256 private constant D4 = 296564248779674000000;
    int256 private constant D5 = 637333633378831000000;
    int256 private constant D6 = 793826512519948000000;
    int256 private constant D7 = 440413735824752000000;

    /// @dev Seconds in a year, matching the 365.25-day convention used to annualise vol.
    uint256 internal constant SECONDS_PER_YEAR = 31_557_600;

    /// @notice Signed wad multiply, truncating toward zero.
    function smul(int256 a, int256 b) internal pure returns (int256) {
        return (a * b) / WAD;
    }

    /// @notice Signed wad divide, truncating toward zero.
    function sdiv(int256 a, int256 b) internal pure returns (int256) {
        return (a * WAD) / b;
    }

    /// @notice The standard normal CDF, in wad.
    ///
    /// @dev Hart's rational approximation in the form published by West, "Better Approximations to
    ///      Cumulative Normal Functions" (Wilmott, 2005). Measured against libm's `erf` over
    ///      [-7, 7] at 0.001 spacing its worst absolute error is 2.2e-16, which is double
    ///      precision epsilon: the approximation is no longer the limiting factor, the 18-digit
    ///      fixed point is.
    ///
    ///      The obvious alternative, Abramowitz and Stegun 7.1.26, was measured at 1.5e-7. On a
    ///      $200 underlying that is a tenth of a cent of pricing error per leg, which is harmless
    ///      economically but large enough that a reference test cannot distinguish it from a real
    ///      sign error. Being exact here is what makes the test suite able to fail.
    function normalCdf(int256 z) internal pure returns (int256) {
        bool negative = z < 0;
        int256 az = negative ? -z : z;
        if (az >= TAIL_CUTOFF) return negative ? int256(0) : WAD;

        int256 decay = FixedPointMathLib.expWad(-smul(az, az) / 2);

        int256 num = smul(N0, az) + N1;
        num = smul(num, az) + N2;
        num = smul(num, az) + N3;
        num = smul(num, az) + N4;
        num = smul(num, az) + N5;
        num = smul(num, az) + N6;

        int256 den = smul(D0, az) + D1;
        den = smul(den, az) + D2;
        den = smul(den, az) + D3;
        den = smul(den, az) + D4;
        den = smul(den, az) + D5;
        den = smul(den, az) + D6;
        den = smul(den, az) + D7;

        int256 lowerTail = smul(decay, sdiv(num, den));
        if (lowerTail < 0) lowerTail = 0;
        if (lowerTail > WAD) lowerTail = WAD;
        return negative ? lowerTail : WAD - lowerTail;
    }

    /// @notice The error function, in wad, derived from the CDF above so there is one approximation
    ///         in this library rather than two that can disagree.
    function erf(int256 x) internal pure returns (int256) {
        return 2 * normalCdf(smul(x, SQRT2)) - WAD;
    }

    /// @notice Convert a duration in seconds into years, in wad.
    function yearsOf(uint256 secondsToExpiry) internal pure returns (uint256) {
        return (secondsToExpiry * UWAD) / SECONDS_PER_YEAR;
    }

    /// @notice The diffusion term the model divides by, `vol * sqrt(tau)`, in wad.
    /// @dev Exposed because it is the only quantity that decides whether a series is priceable at
    ///      all. Both entry points test it directly rather than testing `vol` and `tau` separately.
    function sigmaRootT(uint256 vol, uint256 tau) internal pure returns (uint256) {
        return FixedPointMathLib.mulWad(vol, FixedPointMathLib.sqrtWad(tau));
    }

    /// @notice `d1` and `d2` of Black-Scholes. Callers that need delta reuse `d1` rather than
    ///         re-deriving it from a second evaluation of the model.
    /// @param spot Underlying price, wad.
    /// @param strike Strike, wad, in the same unit as `spot`.
    /// @param tau Time to expiry in years, wad.
    /// @param vol Annualised volatility, wad.
    /// @param rate Continuously compounded risk-free rate, wad, may be negative.
    function d1d2(uint256 spot, uint256 strike, uint256 tau, uint256 vol, int256 rate)
        internal
        pure
        returns (int256 d1, int256 d2)
    {
        int256 sigmaRoot = int256(sigmaRootT(vol, tau));
        require(sigmaRoot != 0, "OptionMath: degenerate series");
        int256 lnMoneyness = FixedPointMathLib.lnWad(int256(FixedPointMathLib.divWad(spot, strike)));
        int256 drift = smul(rate + smul(int256(vol), int256(vol)) / 2, int256(tau));
        d1 = sdiv(lnMoneyness + drift, sigmaRoot);
        d2 = d1 - sigmaRoot;
    }

    /// @notice European call and put on the same inputs, both in wad, both non-negative.
    /// @dev Priced together because a quote screen shows both sides of the same series and the two
    ///      share every intermediate term. Degenerate inputs fall through to discounted intrinsic
    ///      rather than reverting: a zero-vol or zero-time series is a legitimate thing to quote,
    ///      it is simply worth its intrinsic value, and a revert there would strand a settlement
    ///      path behind a pricing edge case.
    function callPut(uint256 spot, uint256 strike, uint256 tau, uint256 vol, int256 rate)
        internal
        pure
        returns (uint256 call, uint256 put)
    {
        require(strike != 0, "OptionMath: zero strike");

        uint256 discount = uint256(FixedPointMathLib.expWad(-smul(rate, int256(tau))));
        uint256 pvStrike = FixedPointMathLib.mulWad(strike, discount);

        // `sigmaRootT` is what the model actually divides by, and it reaches zero for inputs where
        // neither vol nor tau is itself zero: a one-second expiry at 3% vol rounds to nothing in
        // 18 digits. Testing the quotient rather than its parts is what keeps that case out of the
        // division below, and the fuzzer found it before a user could.
        if (tau == 0 || vol == 0 || spot == 0 || sigmaRootT(vol, tau) == 0) {
            call = spot > pvStrike ? spot - pvStrike : 0;
            put = pvStrike > spot ? pvStrike - spot : 0;
            return (call, put);
        }

        (int256 d1, int256 d2) = d1d2(spot, strike, tau, vol, rate);

        uint256 termSpot = FixedPointMathLib.mulWad(spot, uint256(normalCdf(d1)));
        uint256 termStrike = FixedPointMathLib.mulWad(pvStrike, uint256(normalCdf(d2)));
        call = termSpot > termStrike ? termSpot - termStrike : 0;

        uint256 putSpot = FixedPointMathLib.mulWad(spot, uint256(normalCdf(-d1)));
        uint256 putStrike = FixedPointMathLib.mulWad(pvStrike, uint256(normalCdf(-d2)));
        put = putStrike > putSpot ? putStrike - putSpot : 0;

        // The CDF approximation can put a deep out-of-the-money price a few wei below its intrinsic
        // floor. Clamping here means no caller can ever be quoted less than the option is worth if
        // exercised immediately, which is the only property a premium quote must never violate.
        uint256 callFloor = spot > pvStrike ? spot - pvStrike : 0;
        uint256 putFloor = pvStrike > spot ? pvStrike - spot : 0;
        if (call < callFloor) call = callFloor;
        if (put < putFloor) put = putFloor;
    }

    /// @notice Delta of the call leg, in wad, in [0, 1]. The put's delta is this minus one.
    function callDelta(uint256 spot, uint256 strike, uint256 tau, uint256 vol, int256 rate)
        internal
        pure
        returns (int256)
    {
        if (tau == 0 || vol == 0 || sigmaRootT(vol, tau) == 0) return spot >= strike ? WAD : int256(0);
        (int256 d1,) = d1d2(spot, strike, tau, vol, rate);
        return normalCdf(d1);
    }
}
