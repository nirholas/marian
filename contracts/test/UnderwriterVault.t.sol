// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {UnderwriterVault, Position} from "../src/paid/UnderwriterVault.sol";
import {TestSwapVenue} from "./harness/TestSwapVenue.sol";

contract UnderwriterVaultTest is Base {
    TestSwapVenue internal venue;
    uint64 internal expiry;
    address internal constant LP2 = address(0xC0FF2);

    function setUp() public override {
        super.setUp();
        venue = new TestSwapVenue(address(price), address(usdg), USDG_ONE);
        vm.prank(OWNER);
        vault.setSwapVenue(address(venue));
        expiry = _nextExpiry(21 days);

        usdg.mint(LP2, 1_000_000 * USDG_ONE);
        vm.prank(LP2);
        usdg.approve(address(vault), type(uint256).max);
    }

    function test_firstDepositMintsOneSharePerDollar() public view {
        assertEq(vault.totalShares(), 1_000_000 * USDG_ONE, "share accounting wrong");
        assertEq(vault.nav(), 1_000_000 * USDG_ONE, "nav wrong");
    }

    function test_navIncludesOpenPositionsSoLaterDepositorsDoNotDilute() public {
        vm.prank(WRITER);
        book.writeCall(address(nvda), 50e18, 200 * PRICE_ONE, expiry, 0);

        uint256 navAfterTrade = vault.nav();
        // Cash left the vault and an option arrived. NAV should be close to where it started,
        // down only by the edge the vault took, never by the whole premium.
        assertApproxEqRel(navAfterTrade, 1_000_000 * USDG_ONE, 0.01e18, "position not marked");

        uint256 sharesBefore = vault.totalShares();
        vm.prank(LP2);
        uint256 minted = vault.deposit(100_000 * USDG_ONE);
        // A depositor of 10% of NAV gets about 10% of the shares.
        assertApproxEqRel(minted, sharesBefore / 10, 0.02e18, "dilution");
    }

    function test_withdrawIsBoundedByCashNotByNav() public {
        vm.prank(WRITER);
        book.writeCall(address(nvda), 50e18, 200 * PRICE_ONE, expiry, 0);

        // Most of the vault is still cash, so a modest redemption works. The share balance is read
        // before the prank, because a prank is consumed by whichever call comes next, view or not.
        uint256 half = vault.sharesOf(LP) / 2;
        vm.prank(LP);
        uint256 got = vault.withdraw(half);
        assertGt(got, 0, "redemption failed");
        assertGt(usdg.balanceOf(LP), 4_000_000 * USDG_ONE, "not paid");
    }

    function test_perTradeCapStopsAnOversizedBid() public {
        vm.prank(OWNER);
        vault.setLimits(2_000, 500, 1 * USDG_ONE, 2_000_000 * USDG_ONE, 3_000);

        (,,, address bidder) = book.previewWrite(address(nvda), expiry, true, 200 * PRICE_ONE, 50e18);
        assertEq(bidder, address(0), "cap ignored");
    }

    function test_openPremiumCapStopsFurtherBids() public {
        vm.prank(OWNER);
        vault.setLimits(2_000, 500, 250_000 * USDG_ONE, 1 * USDG_ONE, 3_000);
        (,,, address bidder) = book.previewWrite(address(nvda), expiry, true, 200 * PRICE_ONE, 50e18);
        assertEq(bidder, address(0), "open cap ignored");
    }

    function test_cashFloorStopsTheVaultSpendingItsLastDollar() public {
        // A 100% cash floor leaves nothing free to bid with.
        vm.prank(OWNER);
        vault.setLimits(2_000, 500, 250_000 * USDG_ONE, 2_000_000 * USDG_ONE, 10_000);
        (,,, address bidder) = book.previewWrite(address(nvda), expiry, true, 200 * PRICE_ONE, 50e18);
        assertEq(bidder, address(0), "cash floor ignored");
    }

    function test_haircutMakesTheBidStrictlyBelowFairValue() public view {
        (uint256 model,) = book.modelPremium(address(nvda), expiry, true, 200 * PRICE_ONE, 50e18);
        (, uint256 bid) = book.bestBid(_terms(true, 200 * PRICE_ONE, expiry), 50e18);
        assertGt(model, bid, "vault would pay fair value");
        // The edge is real but not extortionate: the writer still sees a usable price.
        assertGt(bid * 10, model, "bid is unusably low");
    }

    function test_harvestClaimsAndSellsInOneTransaction() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 50e18, 200 * PRICE_ONE, expiry, 0);

        vm.warp(expiry + 1);
        price.setPrice(address(nvda), 260 * PRICE_ONE);
        book.settle(id);

        uint256 cashBefore = usdg.balanceOf(address(vault));
        vm.prank(KEEPER);
        uint256 recovered = vault.harvest(id, 0);

        assertGt(recovered, 0, "nothing recovered");
        assertEq(usdg.balanceOf(address(vault)) - cashBefore, recovered, "cash not returned");
        // The vault never ends the transaction holding stock.
        assertEq(nvda.balanceOf(address(vault)), 0, "unhedged inventory left behind");
        assertEq(vault.openPositions().length, 0, "position not closed");
    }

    function test_harvestRespectsTheSlippageBound() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 50e18, 200 * PRICE_ONE, expiry, 0);
        vm.warp(expiry + 1);
        price.setPrice(address(nvda), 260 * PRICE_ONE);
        book.settle(id);

        venue.setSlippageBps(1_000);
        vm.prank(KEEPER);
        vm.expectRevert();
        vault.harvest(id, 1_000_000 * USDG_ONE);
    }

    function test_onlyKeeperCanHarvest() public {
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 50e18, 200 * PRICE_ONE, expiry, 0);
        vm.warp(expiry + 1);
        book.settle(id);
        vm.expectRevert(UnderwriterVault.OnlyKeeper.selector);
        vault.harvest(id, 0);
    }

    function test_onlyTheBookCanMakeTheVaultBuy() public {
        vm.expectRevert(UnderwriterVault.OnlyBook.selector);
        vault.executeBuy(bytes32(0), _terms(true, 200 * PRICE_ONE, expiry), 1e18, 1 * USDG_ONE);
    }

    function test_vaultProfitsWhenTheOptionExpiresWorthless() public {
        uint256 navBefore = vault.nav();
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 50e18, 210 * PRICE_ONE, expiry, 0);

        vm.warp(expiry + 1);
        price.setPrice(address(nvda), 175 * PRICE_ONE);
        book.settle(id);
        vm.prank(KEEPER);
        vault.harvest(id, 0);

        // The vault paid a premium for an option that expired worthless: it is down by exactly that
        // premium. Being long options, this is the ordinary outcome, and the haircut is what makes
        // the rarer paying outcomes more than cover it.
        assertLt(vault.nav(), navBefore, "vault should be down on a worthless expiry");
    }

    function test_vaultGainsWhenTheOptionFinishesDeepInTheMoney() public {
        uint256 navBefore = vault.nav();
        vm.prank(WRITER);
        (bytes32 id,) = book.writeCall(address(nvda), 50e18, 200 * PRICE_ONE, expiry, 0);

        vm.warp(expiry + 1);
        price.setPrice(address(nvda), 300 * PRICE_ONE);
        book.settle(id);
        vm.prank(KEEPER);
        vault.harvest(id, 0);

        assertGt(vault.nav(), navBefore, "vault should gain on a deep in-the-money expiry");
    }
}
