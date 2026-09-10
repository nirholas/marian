// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {TermRepo, Note, NoteState} from "../src/savings/TermRepo.sol";

contract TermRepoTest is Base {
    TermRepo internal repo;
    address internal constant SAVER = address(0x5A7E);
    address internal constant BORROWER = address(0xB0AA);

    uint32 internal constant TERM = 30 days;

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        repo = new TermRepo(OWNER, address(registry), address(price), address(usdg));
        repo.setTerm(TERM, 800);
        repo.setTerm(90 days, 950);
        vm.stopPrank();

        usdg.mint(SAVER, 200_000 * USDG_ONE);
        vm.prank(SAVER);
        usdg.approve(address(repo), type(uint256).max);

        nvda.mint(BORROWER, 1_000e18);
        usdg.mint(BORROWER, 200_000 * USDG_ONE);
        vm.startPrank(BORROWER);
        nvda.approve(address(repo), type(uint256).max);
        usdg.approve(address(repo), type(uint256).max);
        vm.stopPrank();
    }

    function test_interestIsTheAdvertisedRateForTheTerm() public view {
        // $100,000 at 8% for 30 days.
        uint256 expected = (100_000 * USDG_ONE * 800 * uint256(TERM)) / (10_000 * 31_557_600);
        assertEq(repo.interestFor(100_000 * USDG_ONE, TERM), expected, "rate wrong");
        assertApproxEqRel(expected, 657 * USDG_ONE, 0.01e18, "not roughly 0.66% of principal");
    }

    /// @notice The claim the product is sold on: from the moment a deposit is matched, the whole
    ///         term's interest is a balance in this contract rather than a forecast.
    function test_matchingEscrowsTheEntireTermsInterestImmediately() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(80_000 * USDG_ONE, TERM);

        uint256 expectedInterest = repo.interestFor(80_000 * USDG_ONE, TERM);
        // $80,000 needs 150% plus the 25% halt buffer, so $150,000. 900 NVDA at $180 is $162,000.
        uint256 collateral = 900e18;

        uint256 heldBefore = usdg.balanceOf(address(repo));
        vm.prank(BORROWER);
        repo.borrow(id, address(nvda), collateral);

        // The borrower took the principal out and put the interest in.
        assertEq(heldBefore - usdg.balanceOf(address(repo)), 80_000 * USDG_ONE - expectedInterest, "escrow wrong");
        Note memory n = repo.noteOf(id);
        assertEq(n.interest, expectedInterest, "interest not recorded");
        assertEq(uint8(n.state), uint8(NoteState.Matched), "not matched");
    }

    function test_saverGetsPrincipalPlusInterestAtMaturity() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(80_000 * USDG_ONE, TERM);
        vm.prank(BORROWER);
        repo.borrow(id, address(nvda), 900e18);

        skip(TERM + 1);
        vm.prank(BORROWER);
        repo.repay(id);

        uint256 before = usdg.balanceOf(SAVER);
        vm.prank(SAVER);
        uint256 got = repo.redeem(id);
        assertEq(got, 80_000 * USDG_ONE + repo.interestFor(80_000 * USDG_ONE, TERM), "wrong payout");
        assertEq(usdg.balanceOf(SAVER) - before, got, "not delivered");
    }

    function test_unmatchedDepositEarnsNothingAndCancelsFreely() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(50_000 * USDG_ONE, TERM);
        Note memory n = repo.noteOf(id);
        assertEq(n.interest, 0, "idle money should earn nothing");

        uint256 before = usdg.balanceOf(SAVER);
        vm.prank(SAVER);
        repo.cancel(id);
        assertEq(usdg.balanceOf(SAVER) - before, 50_000 * USDG_ONE, "not refunded in full");
    }

    function test_cannotCancelOnceMatched() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(80_000 * USDG_ONE, TERM);
        vm.prank(BORROWER);
        repo.borrow(id, address(nvda), 900e18);
        vm.prank(SAVER);
        vm.expectRevert(abi.encodeWithSelector(TermRepo.WrongState.selector, id, NoteState.Matched));
        repo.cancel(id);
    }

    function test_borrowerMustPostCollateralAboveTheRatioAndBuffer() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(100_000 * USDG_ONE, TERM);

        // 150% ratio, then a 25% halt buffer on top: $187,500 of collateral for $100,000.
        uint256 required = repo.collateralRequired(100_000 * USDG_ONE, address(nvda));
        assertEq(required, 187_500 * USDG_ONE, "requirement wrong");

        // $180,000 of NVDA is not enough.
        vm.prank(BORROWER);
        vm.expectRevert();
        repo.borrow(id, address(nvda), 1_000e18);
    }

    function test_foreclosureOnlyAfterMaturityAndGrace() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(80_000 * USDG_ONE, TERM);
        vm.prank(BORROWER);
        repo.borrow(id, address(nvda), 900e18);

        vm.expectRevert(abi.encodeWithSelector(TermRepo.NotMature.selector, id));
        repo.foreclose(id);

        skip(TERM + 1);
        vm.expectRevert(abi.encodeWithSelector(TermRepo.StillInGrace.selector, id));
        repo.foreclose(id);
    }

    function test_foreclosureMakesTheSaverWhole() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(80_000 * USDG_ONE, TERM);
        vm.prank(BORROWER);
        repo.borrow(id, address(nvda), 900e18);

        skip(TERM + 2 days);

        address rescuer = address(0xBEEF);
        usdg.mint(rescuer, 200_000 * USDG_ONE);
        vm.startPrank(rescuer);
        usdg.approve(address(repo), type(uint256).max);
        repo.foreclose(id);
        vm.stopPrank();

        assertEq(nvda.balanceOf(rescuer), 900e18, "collateral not delivered");
        vm.prank(SAVER);
        uint256 got = repo.redeem(id);
        assertEq(got, 80_000 * USDG_ONE + repo.interestFor(80_000 * USDG_ONE, TERM), "saver not made whole");
    }

    function test_haltDefersForeclosureWithoutLosingTheClaim() public {
        vm.prank(SAVER);
        uint256 id = repo.lend(80_000 * USDG_ONE, TERM);
        vm.prank(BORROWER);
        repo.borrow(id, address(nvda), 900e18);

        skip(TERM + 2 days);
        nvda.setTokenPaused(true);

        address rescuer = address(0xBEEF);
        usdg.mint(rescuer, 200_000 * USDG_ONE);
        vm.startPrank(rescuer);
        usdg.approve(address(repo), type(uint256).max);
        vm.expectRevert();
        repo.foreclose(id);

        // The claim is unchanged when the freeze lifts.
        nvda.setTokenPaused(false);
        repo.foreclose(id);
        vm.stopPrank();
        assertEq(nvda.balanceOf(rescuer), 900e18, "claim lost across the halt");
    }

    function test_unknownTermIsRefused() public {
        vm.prank(SAVER);
        vm.expectRevert(abi.encodeWithSelector(TermRepo.UnknownTerm.selector, uint32(45 days)));
        repo.lend(1_000 * USDG_ONE, 45 days);
    }

    function test_termsAreEnumerableForAUi() public view {
        uint32[] memory list = repo.terms();
        assertEq(list.length, 2, "terms not listed");
        assertEq(repo.aprForTerm(list[0]), 800, "apr missing");
    }
}
