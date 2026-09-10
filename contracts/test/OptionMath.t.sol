// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OptionMath} from "../src/paid/OptionMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Every expected value in this file was produced independently in double precision, by
///         `scripts/reference-prices.py`, from the textbook Black-Scholes formulas and libm's
///         `erf`. Nothing here is a fixture recorded from this implementation, which is the only
///         way a pricing test can actually fail.
contract OptionMathTest is Test {
    /// @dev The Hart approximation lands within double-precision epsilon of libm, so the CDF is
    ///      asserted to 1e-12 in probability and prices to 1e-10 of a dollar. These are tight enough
    uint256 constant CDF_TOL = 1e6;
    ///      that a wrong sign, a dropped discount factor or a swapped d1/d2 cannot hide inside them.

    uint256 constant PRICE_TOL = 1e8;

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        return a > b ? uint256(a - b) : uint256(b - a);
    }

    function test_normalCdf_matchesLibm() public pure {
        assertApproxEqAbs(uint256(OptionMath.normalCdf(0)), 500000000000000000, CDF_TOL, "N(0)");
        assertApproxEqAbs(uint256(OptionMath.normalCdf(1e18)), 841344746068542976, CDF_TOL, "N(1)");
        assertApproxEqAbs(uint256(OptionMath.normalCdf(-1.96e18)), 24997895148220428, CDF_TOL, "N(-1.96)");
        assertApproxEqAbs(uint256(OptionMath.normalCdf(3e18)), 998650101968369920, CDF_TOL, "N(3)");
        assertApproxEqAbs(uint256(OptionMath.normalCdf(-3e18)), 1349898031630104, CDF_TOL, "N(-3)");
    }

    function test_normalCdf_isSymmetricAndBounded() public pure {
        for (int256 x = -5e18; x <= 5e18; x += 25e16) {
            int256 up = OptionMath.normalCdf(x);
            int256 down = OptionMath.normalCdf(-x);
            assertLe(uint256(up), 1e18, "cdf above one");
            assertApproxEqAbs(uint256(up + down), 1e18, CDF_TOL, "N(x)+N(-x) != 1");
        }
    }

    function test_normalCdf_isMonotonic() public pure {
        int256 previous = 0;
        for (int256 x = -6e18; x <= 6e18; x += 1e17) {
            int256 v = OptionMath.normalCdf(x);
            assertGe(v, previous, "cdf decreased");
            previous = v;
        }
    }

    function test_atTheMoneyOneYear() public pure {
        (uint256 c, uint256 p) = OptionMath.callPut(100e18, 100e18, 1e18, 0.2e18, 0.05e18);
        assertApproxEqAbs(c, 10450583572185565184, PRICE_TOL, "call");
        assertApproxEqAbs(p, 5573526022256970752, PRICE_TOL, "put");
    }

    function test_outOfTheMoneyMonthlyCall() public pure {
        (uint256 c, uint256 p) = OptionMath.callPut(180e18, 200e18, 82135523613963040, 0.45e18, 0.04e18);
        assertApproxEqAbs(c, 2977305831397067776, PRICE_TOL, "call");
        assertApproxEqAbs(p, 22321299860440489984, PRICE_TOL, "put");
    }

    function test_inTheMoneyMonthlyCall() public pure {
        (uint256 c, uint256 p) = OptionMath.callPut(180e18, 150e18, 82135523613963040, 0.45e18, 0.04e18);
        assertApproxEqAbs(c, 31202164585874612224, PRICE_TOL, "call");
        assertApproxEqAbs(p, 710160107657200640, PRICE_TOL, "put");
    }

    function test_shortDatedHighVol() public pure {
        (uint256 c, uint256 p) = OptionMath.callPut(100e18, 100e18, 19164955509924708, 0.6e18, 0.04e18);
        assertApproxEqAbs(c, 3349950054931831296, PRICE_TOL, "call");
        assertApproxEqAbs(p, 3273319609026664448, PRICE_TOL, "put");
    }

    function test_deepOutOfTheMoney() public pure {
        (uint256 c, uint256 p) = OptionMath.callPut(50e18, 100e18, 1e18, 0.3e18, 0.05e18);
        assertApproxEqAbs(c, 117413196812552688, PRICE_TOL, "call");
        assertApproxEqAbs(p, 45240355646883962880, PRICE_TOL, "put");
    }

    function test_deepInTheMoney() public pure {
        (uint256 c, uint256 p) = OptionMath.callPut(200e18, 100e18, 0.5e18, 0.25e18, 0.03e18);
        assertApproxEqAbs(c, 101488978155357224960, PRICE_TOL, "call");
        assertApproxEqAbs(p, 172115663490699, PRICE_TOL, "put");
    }

    function test_deltaMatchesReference() public pure {
        assertApproxEqAbs(
            uint256(OptionMath.callDelta(100e18, 100e18, 1e18, 0.2e18, 0.05e18)),
            636830651175619072,
            CDF_TOL,
            "atm delta"
        );
        assertApproxEqAbs(
            uint256(OptionMath.callDelta(200e18, 100e18, 0.5e18, 0.25e18, 0.03e18)),
            999978825312673664,
            CDF_TOL,
            "itm delta"
        );
    }

    function test_putCallParityHolds() public pure {
        uint256 spot = 180e18;
        uint256 strike = 175e18;
        uint256 tau = 0.25e18;
        int256 rate = 0.05e18;
        (uint256 c, uint256 p) = OptionMath.callPut(spot, strike, tau, 0.4e18, rate);

        // C - P == S - K*e^{-rT}, exactly, for any vol. Parity is the one identity that does not
        // depend on the model being right, so it catches a sign or discount-factor error that a
        // reference-value comparison could absorb into its tolerance.
        int256 lhs = int256(c) - int256(p);
        uint256 pvStrike = FixedPointMathLib.mulWad(strike, uint256(FixedPointMathLib.expWad(-(rate * int256(tau)) / 1e18)));
        int256 rhs = int256(spot) - int256(pvStrike);
        assertApproxEqAbs(_absDiff(lhs, rhs), 0, PRICE_TOL, "put-call parity");
    }

    function test_degenerateInputsFallThroughToIntrinsic() public pure {
        (uint256 c0, uint256 p0) = OptionMath.callPut(120e18, 100e18, 0, 0.4e18, 0);
        assertEq(c0, 20e18, "zero tau call is intrinsic");
        assertEq(p0, 0, "zero tau put is zero");

        (uint256 c1, uint256 p1) = OptionMath.callPut(80e18, 100e18, 0.5e18, 0, 0);
        assertEq(c1, 0, "zero vol otm call");
        assertEq(p1, 20e18, "zero vol itm put");
    }

    function test_priceNeverBelowIntrinsic() public pure {
        for (uint256 s = 50e18; s <= 150e18; s += 5e18) {
            (uint256 c, uint256 p) = OptionMath.callPut(s, 100e18, 0.1e18, 0.35e18, 0);
            uint256 callFloor = s > 100e18 ? s - 100e18 : 0;
            uint256 putFloor = 100e18 > s ? 100e18 - s : 0;
            assertGe(c, callFloor, "call below intrinsic");
            assertGe(p, putFloor, "put below intrinsic");
        }
    }

    function test_callRisesWithSpotAndVol() public pure {
        (uint256 lowSpot,) = OptionMath.callPut(90e18, 100e18, 0.25e18, 0.3e18, 0);
        (uint256 highSpot,) = OptionMath.callPut(110e18, 100e18, 0.25e18, 0.3e18, 0);
        assertGt(highSpot, lowSpot, "call not increasing in spot");

        (uint256 lowVol,) = OptionMath.callPut(100e18, 100e18, 0.25e18, 0.2e18, 0);
        (uint256 highVol,) = OptionMath.callPut(100e18, 100e18, 0.25e18, 0.5e18, 0);
        assertGt(highVol, lowVol, "call not increasing in vol");
    }

    function testFuzz_pricesStayBounded(uint96 spotRaw, uint96 strikeRaw, uint32 secs, uint64 volRaw) public pure {
        uint256 spot = bound(uint256(spotRaw), 1e15, 1e24);
        uint256 strike = bound(uint256(strikeRaw), 1e15, 1e24);
        uint256 tau = OptionMath.yearsOf(bound(uint256(secs), 0, 3 * 365 days));
        uint256 vol = bound(uint256(volRaw), 0, 5e18);

        (uint256 c, uint256 p) = OptionMath.callPut(spot, strike, tau, vol, 0);
        // A call is never worth more than the stock and a put never more than the strike. These are
        // model-free no-arbitrage bounds: any violation is a bug regardless of the inputs.
        assertLe(c, spot, "call above spot");
        assertLe(p, strike, "put above strike");
    }
}
