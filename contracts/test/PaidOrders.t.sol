// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {PaidOrders, Series} from "../src/paid/PaidOrders.sol";
import {SeriesTerms} from "../src/paid/IOptionBuyer.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";
import {Adjustment} from "../src/core/Corporate.sol";

contract PaidOrdersTest is Base {
    uint64 internal expiry;

    function setUp() public override {
        super.setUp();
        expiry = _nextExpiry(21 days);
    }

    // ------------------------------------------------------------ writing

    function test_writeCall_paysThePremiumUpFront() public {
        uint256 before = usdg.balanceOf(WRITER);

        vm.prank(WRITER);
        (bytes32 id, uint256 netPremium) = book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 0);

        assertGt(netPremium, 0, "no premium");
        assertEq(usdg.balanceOf(WRITER) - before, netPremium, "premium not delivered");
        assertEq(nvda.balanceOf(WRITER), 990e18, "shares not escrowed");
        assertEq(nvda.balanceOf(address(book)), 10e18, "escrow missing");
        assertEq(book.shortOf(id, WRITER), 10e18, "short not recorded");
        assertEq(book.longOf(id, address(vault)), 10e18, "long not recorded");
        assertGt(usdg.balanceOf(FEE_SINK), 0, "fee not taken");
    }

    function test_writePut_locksExactlyTheCashTheSharesWouldCost() public {
        uint256 strike = 160 * PRICE_ONE;
        uint256 expectedLock = (10e18 * strike * USDG_ONE) / (1e18 * PRICE_ONE);

        uint256 before = usdg.balanceOf(WRITER);
        vm.prank(WRITER);
        (, uint256 netPremium) = book.writePut(address(nvda), 10e18, strike, expiry, 0);

        // Locked the strike value, received the premium: the net movement is one minus the other.
        assertEq(before - usdg.balanceOf(WRITER), expectedLock - netPremium, "wrong cash movement");
        assertEq(usdg.balanceOf(address(book)), expectedLock, "escrow wrong");
    }

    function test_writeCall_respectsMinimumPremium() public {
        vm.prank(WRITER);
        vm.expectRevert();
        book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 1_000_000 * USDG_ONE);
    }

    function test_callStrikeMustBeAtOrAboveSpot() public {
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.BadStrike.selector, 170 * PRICE_ONE, 180 * PRICE_ONE));
        book.writeCall(address(nvda), 1e18, 170 * PRICE_ONE, expiry, 0);
    }

    function test_putStrikeMustBeAtOrBelowSpot() public {
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.BadStrike.selector, 190 * PRICE_ONE, 180 * PRICE_ONE));
        book.writePut(address(nvda), 1e18, 190 * PRICE_ONE, expiry, 0);
    }

    function test_strikeOutsideBandIsRefused() public {
        // Band is 50%. A $300 strike on a $180 stock is 66% away.
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.BadStrike.selector, 300 * PRICE_ONE, 180 * PRICE_ONE));
        book.writeCall(address(nvda), 1e18, 300 * PRICE_ONE, expiry, 0);
    }

    function test_expiryMustBeOnTheWeeklyGrid() public {
        uint64 offGrid = expiry + 1 days;
        assertFalse(book.isValidExpiry(offGrid), "grid check wrong");
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.BadExpiry.selector, offGrid));
        book.writeCall(address(nvda), 1e18, 200 * PRICE_ONE, offGrid, 0);
    }

    function test_upcomingExpiriesAreAllOnTheGridAndInTheFuture() public view {
        uint64[] memory dates = book.upcomingExpiries(6);
        for (uint256 i; i < dates.length; ++i) {
            assertTrue(book.isValidExpiry(dates[i]), "off grid");
            assertGt(dates[i], block.timestamp, "in the past");
            if (i > 0) assertEq(dates[i] - dates[i - 1], book.EXPIRY_PERIOD(), "not weekly");
        }
    }

    // ------------------------------------------------------------ settlement

    function test_callOutOfTheMoney_writerGetsEveryShareBack() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 0);

        vm.warp(expiry + 1);
        price.setPrice(address(nvda), 190 * PRICE_ONE);
        book.settle(id);

        vm.prank(WRITER);
        uint256 returned = book.claimShort(id);
        assertEq(returned, 10e18, "writer short-changed");
        assertEq(nvda.balanceOf(WRITER), 1_000e18, "not whole again");
    }

    /// @notice The core economic claim of the product: if the stock gets to your price, you sold at
    ///         your price. Not near it, at it.
    function test_callInTheMoney_writerKeepsExactlyTheStrikeValue() public {
        uint256 strike = 200 * PRICE_ONE;
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, strike, expiry, 0);

        vm.warp(expiry + 1);
        uint256 settlePrice = 250 * PRICE_ONE;
        price.setPrice(address(nvda), settlePrice);
        book.settle(id);

        vm.prank(WRITER);
        uint256 keptRaw = book.claimShort(id);

        // What the writer kept, valued at the settlement price, is the strike times the size.
        uint256 keptValue1e8 = (keptRaw * settlePrice) / 1e18;
        uint256 strikeValue1e8 = (10e18 * strike) / 1e18;
        assertApproxEqAbs(keptValue1e8, strikeValue1e8, 10, "writer did not sell at their price");

        // And the long took the rest, so nothing is stranded.
        vm.prank(address(vault));
        uint256 longPayout = book.claimLong(id);
        assertApproxEqAbs(keptRaw + longPayout, 10e18, 10, "escrow not conserved");
    }

    function test_putInTheMoney_writerHoldsWhatTheSharesAreWorth() public {
        uint256 strike = 160 * PRICE_ONE;
        vm.prank(WRITER);
        (bytes32 id,) = book.writePut(address(nvda), 10e18, strike, expiry, 0);

        vm.warp(expiry + 1);
        uint256 settlePrice = 140 * PRICE_ONE;
        price.setPrice(address(nvda), settlePrice);
        book.settle(id);

        vm.prank(WRITER);
        uint256 returnedUsdg = book.claimShort(id);

        // Dollars left equal the value of the shares they would have bought at the strike: the
        // same position as having bought at $160 and watched it fall to $140.
        uint256 expected = (10e18 * settlePrice * USDG_ONE) / (1e18 * PRICE_ONE);
        assertApproxEqAbs(returnedUsdg, expected, 10, "put writer position wrong");
    }

    function test_putOutOfTheMoney_writerGetsEveryDollarBack() public {
        uint256 strike = 160 * PRICE_ONE;
        uint256 lock = (10e18 * strike * USDG_ONE) / (1e18 * PRICE_ONE);

        vm.prank(WRITER);
        (bytes32 id,) = book.writePut(address(nvda), 10e18, strike, expiry, 0);

        vm.warp(expiry + 1);
        price.setPrice(address(nvda), 175 * PRICE_ONE);
        book.settle(id);

        vm.prank(WRITER);
        assertEq(book.claimShort(id), lock, "cash not returned in full");
    }

    function test_cannotSettleBeforeExpiryAndCannotSettleTwice() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 1e18, 200 * PRICE_ONE, expiry, 0);

        vm.expectRevert(abi.encodeWithSelector(PaidOrders.NotExpired.selector, id));
        book.settle(id);

        vm.warp(expiry + 1);
        book.settle(id);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.AlreadySettled.selector, id));
        book.settle(id);
    }

    function test_cannotClaimBeforeSettlement() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 1e18, 200 * PRICE_ONE, expiry, 0);
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.NotSettled.selector, id));
        book.claimShort(id);
    }

    // ------------------------------------------------------------ halts

    function test_haltDefersSettlementAndThenItCompletes() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 0);

        vm.warp(expiry + 1);
        price.setPrice(address(nvda), 250 * PRICE_ONE);
        nvda.setTokenPaused(true);

        vm.expectRevert(abi.encodeWithSelector(PaidOrders.PriceUnavailable.selector, PriceStatus.TokenPaused));
        book.settle(id);

        // The issuer lifts the halt. Settlement takes the first observation available after it.
        nvda.setTokenPaused(false);
        book.settle(id);
        Series memory s = book.seriesOf(id);
        assertTrue(s.settled, "still unsettled");
        assertEq(s.settlePriceRaw1e8, 250 * PRICE_ONE, "wrong settlement price");
    }

    function test_registryWideHaltAlsoDefersSettlement() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 1e18, 200 * PRICE_ONE, expiry, 0);
        vm.warp(expiry + 1);
        nvda.setRegistryPaused(true);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.PriceUnavailable.selector, PriceStatus.TokenPaused));
        book.settle(id);
    }

    function test_oraclePauseDefersSettlementWithoutFreezingTransfers() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 1e18, 200 * PRICE_ONE, expiry, 0);
        vm.warp(expiry + 1);
        nvda.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.PriceUnavailable.selector, PriceStatus.IssuerOraclePaused));
        book.settle(id);
        // Transfers still work while only the price is disavowed, which is the whole distinction.
        assertFalse(nvda.paused(), "token should not be frozen");
    }

    function test_cannotWriteWhileHalted() public {
        nvda.setTokenPaused(true);
        vm.prank(WRITER);
        vm.expectRevert();
        book.writeCall(address(nvda), 1e18, 200 * PRICE_ONE, expiry, 0);
    }

    // ------------------------------------------------------------ corporate actions

    /// @notice A dividend on this chain is a multiplier step. The writer of a covered call is
    ///         entitled to keep it, and they only do if the strike moves with it.
    function test_dividendAccrualAdjustsTheStrikeAndStaysWithTheWriter() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 0);
        Series memory before = book.seriesOf(id);
        assertEq(before.strikeRaw1e8, 200 * PRICE_ONE, "raw strike wrong at open");

        // NVDA's live multiplier on 2026-09-10 was 1.000775159164630595. Use that exact step.
        uint256 next = 1_000775159164630595;
        nvda.setMultiplier(next);
        book.adjust(id);

        Series memory adjusted = book.seriesOf(id);
        assertEq(adjusted.strikeRaw1e8, (200 * PRICE_ONE * next) / 1e18, "strike not adjusted");
        assertEq(adjusted.strikePerShare1e8, 200 * PRICE_ONE, "the promise changed");

        // The raw price rises by the same ratio when the accrual lands, so moneyness is untouched:
        // the writer is not assigned on a payout they were owed.
        uint256 newSpot = (180 * PRICE_ONE * next) / 1e18;
        vm.warp(expiry + 1);
        price.setPrice(address(nvda), newSpot);
        book.settle(id);

        vm.prank(WRITER);
        assertEq(book.claimShort(id), 10e18, "accrual leaked to the long side");
    }

    function test_reverseSplitAdjustsTheStrikeTheOtherWay() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 0);

        // A one-for-two reverse split halves the shares each raw unit carries.
        nvda.setMultiplier(0.5e18);
        book.adjust(id);

        Series memory s = book.seriesOf(id);
        assertEq(s.strikeRaw1e8, 100 * PRICE_ONE, "reverse split not handled");
    }

    function test_scheduledActionIsVisibleBeforeItLands() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 1e18, 200 * PRICE_ONE, expiry, 0);

        uint256 landsAt = block.timestamp + 3 days;
        nvda.scheduleMultiplier(1.02e18, landsAt);

        Adjustment memory pending = book.pendingAdjustment(id);
        assertEq(pending.ratioWad, 1.02e18, "pending ratio wrong");
        assertEq(pending.effectiveAt, landsAt, "pending date wrong");
    }

    function test_settlementSyncsAnUnadjustedStrike() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 0);

        // Nobody calls adjust(). Settlement must still be correct.
        nvda.setMultiplier(1.05e18);
        vm.warp(expiry + 1);
        price.setPrice(address(nvda), (180 * PRICE_ONE * 1.05e18) / 1e18);
        book.settle(id);

        Series memory s = book.seriesOf(id);
        assertEq(s.strikeRaw1e8, (200 * PRICE_ONE * 1.05e18) / 1e18, "settle did not sync");
    }

    // ------------------------------------------------------------ preview and invariants

    function test_previewShowsTheCapAlongsideThePremium() public view {
        (uint256 premium, uint256 fee, uint256 maxProceeds, address buyer) =
            book.previewWrite(address(nvda), expiry, true, 200 * PRICE_ONE, 10e18);

        assertEq(buyer, address(vault), "no bidder");
        assertGt(premium, 0, "no premium");
        assertGt(fee, 0, "no fee");
        // 10 shares called away at $200 is $2,000, plus the premium, and not a cent more however
        // far the stock runs. The interface has to be able to say that number.
        uint256 strikeValue = 2_000 * USDG_ONE;
        assertEq(maxProceeds, strikeValue + premium, "cap wrong");
    }

    function test_modelPremiumIsPositiveAndFallsAsTheStrikeRises() public view {
        (uint256 near,) = book.modelPremium(address(nvda), expiry, true, 190 * PRICE_ONE, 1e18);
        (uint256 far,) = book.modelPremium(address(nvda), expiry, true, 230 * PRICE_ONE, 1e18);
        assertGt(near, far, "premium did not fall with strike");
        assertGt(far, 0, "far strike worthless");
    }

    function test_vaultBidsBelowTheModel() public view {
        (uint256 model,) = book.modelPremium(address(nvda), expiry, true, 200 * PRICE_ONE, 10e18);
        (, uint256 bid) = book.bestBid(_terms(true, 200 * PRICE_ONE, expiry), 10e18);
        assertLt(bid, model, "vault bid at or above fair value");
        assertGt(bid, 0, "vault not bidding");
    }

    /// @dev The invariant that makes the product safe to describe in one sentence: whatever the
    ///      settlement price, the two sides together can never claim more than was escrowed.
    function testFuzz_escrowIsNeverOverdrawn(uint64 strikeMul, uint64 settleMul) public {
        uint256 spot = 180 * PRICE_ONE;
        uint256 strike = bound(uint256(strikeMul), spot, (spot * 14_000) / 10_000);
        strike = (strike / PRICE_ONE) * PRICE_ONE;
        vm.assume(strike >= spot);
        uint256 settlePrice = bound(uint256(settleMul), 1 * PRICE_ONE, 2_000 * PRICE_ONE);

        // Far enough out and the option is genuinely worth less than the smallest unit of USDG, so
        // there is no bid and no trade to test. That case has its own test below; here it is
        // skipped so the invariant is exercised on strikes that can actually be written.
        (,,, address bidder) = book.previewWrite(address(nvda), expiry, true, strike, 10e18);
        vm.assume(bidder != address(0));

        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, strike, expiry, 0);

        vm.warp(expiry + 1);
        price.setPrice(address(nvda), settlePrice);
        book.settle(id);

        uint256 escrowBefore = nvda.balanceOf(address(book));
        vm.prank(WRITER);
        uint256 kept = book.claimShort(id);
        vm.prank(address(vault));
        uint256 paid = book.claimLong(id);

        assertLe(kept + paid, escrowBefore, "escrow overdrawn");
        assertEq(nvda.balanceOf(address(book)), escrowBefore - kept - paid, "accounting drift");
    }

    /// @notice A strike far enough out to be worth less than one millionth of a dollar has no bid,
    ///         and the venue says so instead of writing a position for nothing. The preview surface
    ///         reports the same thing before the user commits, which is where a UI catches it.
    function test_farStrikeHasNoBidAndSaysSoBeforehand() public {
        uint256 farStrike = 269 * PRICE_ONE;
        (uint256 premium,,, address bidder) = book.previewWrite(address(nvda), expiry, true, farStrike, 10e18);
        assertEq(bidder, address(0), "should be no bidder");
        assertEq(premium, 0, "should be no premium");

        bytes32 id = book.seriesIdOf(address(nvda), expiry, true, farStrike);
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(PaidOrders.NoBid.selector, id));
        book.writeCall(address(nvda), 10e18, farStrike, expiry, 0);
    }

    function test_notionalIsBookedAndReleased() public {
        uint256 before = registry.openNotional(address(nvda));
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 10e18, 200 * PRICE_ONE, expiry, 0);
        assertEq(registry.openNotional(address(nvda)) - before, 1_800 * PRICE_ONE, "notional not booked");

        vm.warp(expiry + 1);
        book.settle(id);
        vm.prank(WRITER);
        book.claimShort(id);
        assertEq(registry.openNotional(address(nvda)), before, "notional not released");
    }
}
