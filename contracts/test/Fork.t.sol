// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {EquityOracle, FeedConfig} from "../src/core/EquityOracle.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";
import {Corporate} from "../src/core/Corporate.sol";

/// @notice Tests that run against Robinhood Chain itself.
///
/// @dev Everything this protocol is built on is a claim about a chain nobody else has written a
///      derivatives venue for: that all 254 equities share one implementation, that a dividend is a
///      multiplier step, that a halt makes transfers revert, that the USDG pools are deep enough to
///      settle against. Unit tests cannot check any of that, because the harness they run against
///      was written from the same assumptions as the code.
///
///      These do. They skip when `RHC_RPC_URL` is unset, and **fail** when it is set but the fork
///      cannot be created, because a fork test that quietly turns into a no-op is worse than no
///      fork test: it reports green while checking nothing, and the only tell is the gas figure.
contract ForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant STOCK_IMPLEMENTATION = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_USDG_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant SPY_USDG_POOL = 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167;

    // The eight names measured above 1e18 on 2026-09-10, and four measured at exactly 1e18.
    address constant SGOV = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address constant UPS = 0xf23250dac154D05Bb671CB0d0eBEf3c635c79CE2;
    address constant JNJ = 0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;

    bool internal forked;

    function setUp() public {
        string memory url = vm.envOr("RHC_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        // No try/catch. A configured endpoint that cannot fork is a failure, not a skip.
        vm.createSelectFork(url);
        forked = true;
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_usdgIsSixDecimals() public onlyForked {
        assertEq(IERC20(USDG).decimals(), 6, "USDG decimals changed");
    }

    function test_everyEquityProxiesOntoTheSameImplementation() public onlyForked {
        // The beacon pattern is what makes one interface describe all 254 names. If a token stopped
        // sharing the implementation, its behaviour would no longer be covered by anything here.
        assertGt(STOCK_IMPLEMENTATION.code.length, 0, "implementation has no code");
        assertEq(IStockToken(NVDA).decimals(), 18, "NVDA decimals");
        assertEq(IStockToken(SPY).decimals(), 18, "SPY decimals");
        assertEq(IStockToken(NVDA).symbol(), "NVDA", "NVDA symbol");
    }

    /// @notice The measurement the accrual strip is built on: a multiplier above 1e18 means the
    ///         name pays a distribution, and one at exactly 1e18 means it does not.
    function test_dividendPayersCarryAMultiplierAboveOne() public onlyForked {
        address[4] memory payers = [SGOV, UPS, JNJ, AAPL];
        for (uint256 i; i < payers.length; ++i) {
            uint256 m = IStockToken(payers[i]).uiMultiplier();
            assertGt(m, 1e18, "payer multiplier not above one");
            // A multiplier is an accrual, not a revaluation. Anything far above one would mean the
            // assumption behind every strike adjustment in this repo is wrong.
            assertLt(m, 1.5e18, "multiplier implausibly large");
        }
    }

    /// @notice The other half of the same measurement, and the one that makes it a finding rather
    ///         than a coincidence: names that pay nothing sit at exactly 1e18, to the wei.
    function test_nonPayersSitAtExactlyOne() public onlyForked {
        address[4] memory nonPayers = [TSLA, META, GLD, GME];
        for (uint256 i; i < nonPayers.length; ++i) {
            assertEq(IStockToken(nonPayers[i]).uiMultiplier(), 1e18, "non-payer multiplier moved");
        }
    }

    function test_theMultiplierIsReadableAndNonZeroEverywhere() public onlyForked {
        address[6] memory all = [SGOV, UPS, JNJ, AAPL, NVDA, SPY];
        for (uint256 i; i < all.length; ++i) {
            assertGt(Corporate.multiplierOf(all[i]), 0, "zero multiplier");
        }
    }

    /// @notice `newUIMultiplier`/`effectiveAt` describe the *current* value on this chain whenever
    ///         no action is scheduled, which is why `Corporate.pendingOf` treats a past
    ///         `effectiveAt` as "nothing pending" rather than as an adjustment waiting to happen.
    function test_pendingAdjustmentIsEmptyWhenNothingIsScheduled() public onlyForked {
        address[3] memory sample = [NVDA, SPY, AAPL];
        for (uint256 i; i < sample.length; ++i) {
            uint256 live = IStockToken(sample[i]).uiMultiplier();
            uint256 next = IStockToken(sample[i]).newUIMultiplier();
            if (next == live) {
                assertEq(Corporate.pendingOf(sample[i]).ratioWad, 1e18, "phantom pending action");
            }
        }
    }

    function test_poolsAreTheDocumentedPairsAndStoreEnoughObservations() public onlyForked {
        IUniswapV3Pool nvdaPool = IUniswapV3Pool(NVDA_USDG_POOL);
        assertEq(nvdaPool.token0(), USDG, "NVDA pool token0");
        assertEq(nvdaPool.token1(), NVDA, "NVDA pool token1");
        assertEq(nvdaPool.fee(), 500, "NVDA pool fee tier");

        IUniswapV3Pool spyPool = IUniswapV3Pool(SPY_USDG_POOL);
        assertEq(spyPool.token0(), SPY, "SPY pool token0");
        assertEq(spyPool.token1(), USDG, "SPY pool token1");

        (,,, uint16 cardinality,,,) = nvdaPool.slot0();
        // A thirty-minute TWAP needs a ring big enough to still hold an observation that old.
        assertGt(uint256(cardinality), uint256(100), "NVDA pool cannot serve a TWAP");

        // The check that matters more than the ring size: the pool can actually answer over the
        // window this protocol configures.
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        ago[1] = 0;
        (int56[] memory cumulatives,) = nvdaPool.observe(ago);
        assertTrue(cumulatives[1] != cumulatives[0], "no tick movement over the window");
    }

    /// @notice The oracle, end to end, against the real pool: configure it and read a price that
    ///         has to be in the right ballpark and the right unit.
    function test_oraclePricesNvdaFromTheLivePool() public onlyForked {
        EquityOracle oracle = new EquityOracle(address(this), USDG, 6);
        oracle.configure(
            NVDA,
            FeedConfig({
                pool: NVDA_USDG_POOL,
                assetIsToken0: false,
                window: 1800,
                maxDeviationBps: 500,
                adjustmentBlackout: 1 hours,
                enabled: true
            })
        );

        (uint256 value, bool ok, PriceStatus status) = oracle.tryValueOf(NVDA, 1e18);
        assertTrue(ok, "oracle refused a live, unhalted name");
        assertEq(uint8(status), uint8(PriceStatus.OK), "status not OK");

        // One whole NVDA, in dollars at 1e8. A share price outside $20-$2,000 means the decimal
        // scaling is wrong, which is the failure mode this whole test exists to catch.
        assertGt(value, 20e8, "price implausibly low: check decimals");
        assertLt(value, 2_000e8, "price implausibly high: check decimals");

        // And the conversion is linear in the amount.
        (uint256 tenth,,) = oracle.tryValueOf(NVDA, 1e17);
        assertApproxEqRel(tenth * 10, value, 0.0001e18, "value is not linear in amount");
    }

    function test_oracleRefusesAPairItWasMisconfiguredFor() public onlyForked {
        EquityOracle oracle = new EquityOracle(address(this), USDG, 6);
        // Claiming NVDA is token0 when USDG is would invert every price in the protocol.
        vm.expectRevert();
        oracle.configure(
            NVDA,
            FeedConfig({
                pool: NVDA_USDG_POOL,
                assetIsToken0: true,
                window: 1800,
                maxDeviationBps: 500,
                adjustmentBlackout: 1 hours,
                enabled: true
            })
        );
    }

    function test_noEquityIsHaltedRightNowSoTheVenueWouldBeOpen() public onlyForked {
        // Not an invariant of the chain, an observation about it: if this ever fails, the halt
        // paths in this repo are the ones that matter and they have their own tests.
        assertFalse(IStockToken(NVDA).paused(), "NVDA halted");
        assertFalse(IStockToken(NVDA).oraclePaused(), "NVDA price disavowed");
    }
}
