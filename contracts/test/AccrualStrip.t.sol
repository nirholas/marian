// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {AccrualStrip, Strip, StripState} from "../src/strip/AccrualStrip.sol";

contract AccrualStripTest is Base {
    AccrualStrip internal strip;
    address internal constant HOLDER = address(0x40D3);
    address internal constant BUYER = address(0xB4E7);

    function setUp() public override {
        super.setUp();
        vm.prank(OWNER);
        strip = new AccrualStrip(OWNER, address(registry), address(usdg), FEE_SINK);

        nvda.mint(HOLDER, 1_000e18);
        vm.prank(HOLDER);
        nvda.approve(address(strip), type(uint256).max);

        usdg.mint(BUYER, 100_000 * USDG_ONE);
        vm.prank(BUYER);
        usdg.approve(address(strip), type(uint256).max);
    }

    function _openAndFund(uint256 qty, uint256 ask, uint64 window) internal returns (uint256 id) {
        vm.prank(HOLDER);
        id = strip.offer(address(nvda), qty, ask, uint64(block.timestamp) + window);
        vm.prank(BUYER);
        strip.fund(id);
    }

    /// @notice The whole instrument in one assertion: after the window, the holder is left holding
    ///         exactly the economic shares they started with, and the buyer has the accrual.
    function test_holderKeepsTheirSharesAndTheBuyerTakesTheAccrual() public {
        uint256 id = _openAndFund(100e18, 500 * USDG_ONE, 90 days);
        uint256 startShares = (100e18 * 1e18) / 1e18;

        // SGOV's measured monthly step on this chain is about 0.2%. Three of them.
        nvda.setMultiplier(1.006e18);
        skip(91 days);

        (uint256 buyerRaw, uint256 holderRaw) = strip.settle(id);
        assertEq(buyerRaw + holderRaw, 100e18, "escrow not conserved");

        uint256 holderSharesAfter = (holderRaw * 1.006e18) / 1e18;
        assertApproxEqAbs(holderSharesAfter, startShares, 1e6, "holder lost shares");
        assertGt(buyerRaw, 0, "buyer got nothing");
        assertEq(nvda.balanceOf(BUYER), buyerRaw, "buyer not paid");
    }

    function test_cashIsPaidUpFrontLessTheFee() public {
        uint256 before = usdg.balanceOf(HOLDER);
        _openAndFund(100e18, 1_000 * USDG_ONE, 90 days);
        uint256 fee = (1_000 * USDG_ONE * 50) / 10_000;
        assertEq(usdg.balanceOf(HOLDER) - before, 1_000 * USDG_ONE - fee, "holder paid wrong");
        assertEq(usdg.balanceOf(FEE_SINK), fee, "fee not taken");
    }

    function test_noAccrualMeansTheHolderGetsEverythingBack() public {
        uint256 id = _openAndFund(100e18, 100 * USDG_ONE, 30 days);
        skip(31 days);
        (uint256 buyerRaw, uint256 holderRaw) = strip.settle(id);
        assertEq(buyerRaw, 0, "buyer paid on a non-payer");
        assertEq(holderRaw, 100e18, "holder short-changed");
    }

    function test_reverseSplitPaysTheBuyerNothing() public {
        uint256 id = _openAndFund(100e18, 100 * USDG_ONE, 30 days);
        nvda.setMultiplier(0.5e18);
        skip(31 days);
        (uint256 buyerRaw, uint256 holderRaw) = strip.settle(id);
        assertEq(buyerRaw, 0, "a reverse split is not a payout");
        assertEq(holderRaw, 100e18, "holder short-changed");
    }

    /// @notice Settlement reads no price at all, so a halted token changes the timing and nothing
    ///         else. This is the only product in the repo with that property.
    function test_haltDelaysSettlementButNotItsOutcome() public {
        uint256 id = _openAndFund(100e18, 500 * USDG_ONE, 30 days);
        nvda.setMultiplier(1.004e18);
        skip(31 days);

        (uint256 expectedBuyer,) = strip.previewSettle(id);

        nvda.setTokenPaused(true);
        vm.expectRevert();
        strip.settle(id);

        nvda.setTokenPaused(false);
        skip(45 days);
        (uint256 buyerRaw,) = strip.settle(id);
        assertEq(buyerRaw, expectedBuyer, "outcome changed across the halt");
    }

    function test_cannotSettleEarly() public {
        uint256 id = _openAndFund(100e18, 100 * USDG_ONE, 30 days);
        vm.expectRevert(abi.encodeWithSelector(AccrualStrip.NotMature.selector, id));
        strip.settle(id);
    }

    function test_holderCanCancelAnUnfundedOffer() public {
        vm.prank(HOLDER);
        uint256 id = strip.offer(address(nvda), 100e18, 500 * USDG_ONE, uint64(block.timestamp) + 30 days);
        assertEq(nvda.balanceOf(HOLDER), 900e18, "not escrowed");
        vm.prank(HOLDER);
        strip.cancel(id);
        assertEq(nvda.balanceOf(HOLDER), 1_000e18, "not refunded");
    }

    function test_cannotCancelOnceFunded() public {
        uint256 id = _openAndFund(100e18, 100 * USDG_ONE, 30 days);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(AccrualStrip.WrongState.selector, id, StripState.Funded));
        strip.cancel(id);
    }

    function test_windowMustBeWithinBounds() public {
        vm.startPrank(HOLDER);
        vm.expectRevert();
        strip.offer(address(nvda), 1e18, 1 * USDG_ONE, uint64(block.timestamp) + 1 days);
        vm.expectRevert();
        strip.offer(address(nvda), 1e18, 1 * USDG_ONE, uint64(block.timestamp) + 800 days);
        vm.stopPrank();
    }

    function testFuzz_escrowIsAlwaysConserved(uint96 qty, uint64 endMultiplier) public {
        uint256 quantity = bound(uint256(qty), 1e12, 1_000e18);
        uint256 endM = bound(uint256(endMultiplier), 1, 3e18);
        nvda.mint(HOLDER, quantity);

        vm.prank(HOLDER);
        uint256 id = strip.offer(address(nvda), quantity, 1 * USDG_ONE, uint64(block.timestamp) + 30 days);
        vm.prank(BUYER);
        strip.fund(id);

        nvda.setMultiplier(endM);
        skip(31 days);
        (uint256 buyerRaw, uint256 holderRaw) = strip.settle(id);
        assertEq(buyerRaw + holderRaw, quantity, "escrow not conserved");
    }
}
