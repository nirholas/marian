// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {CreditLine, Loan} from "../src/credit/CreditLine.sol";
import {AssetConfig} from "../src/core/AssetRegistry.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";

contract CreditLineTest is Base {
    CreditLine internal credit;
    address internal constant BORROWER = address(0xB0AA);
    address internal constant LIQUIDATOR = address(0x71D);

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        credit = new CreditLine(OWNER, address(registry), address(price), address(usdg));
        registry.setProduct(address(credit), true);
        credit.setKeeper(KEEPER, true);
        vm.stopPrank();

        usdg.mint(LP, 2_000_000 * USDG_ONE);
        vm.startPrank(LP);
        usdg.approve(address(credit), type(uint256).max);
        credit.supply(1_000_000 * USDG_ONE);
        vm.stopPrank();

        nvda.mint(BORROWER, 500e18);
        usdg.mint(BORROWER, 500_000 * USDG_ONE);
        vm.startPrank(BORROWER);
        nvda.approve(address(credit), type(uint256).max);
        usdg.approve(address(credit), type(uint256).max);
        vm.stopPrank();

        usdg.mint(LIQUIDATOR, 500_000 * USDG_ONE);
        vm.prank(LIQUIDATOR);
        usdg.approve(address(credit), type(uint256).max);
    }

    /// @notice 100 NVDA at $180 is $18,000. At 65% LTV with a 25% halt buffer the borrower may take
    ///         $8,775, not the $11,700 an ordinary lender would offer. The gap is the halt.
    function test_capacityIsLtvMinusTheHaltBuffer() public {
        vm.prank(BORROWER);
        credit.lock(address(nvda), 100e18);

        uint256 capacity = credit.borrowCapacity(BORROWER, address(nvda));
        uint256 gross = (18_000 * USDG_ONE * 6_500) / 10_000;
        uint256 expected = (gross * 7_500) / 10_000;
        assertEq(capacity, expected, "capacity ignores the halt buffer");
        assertEq(expected, 8_775 * USDG_ONE, "arithmetic drifted");
    }

    function test_borrowAgainstIsOneCall() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 5_000 * USDG_ONE);

        assertEq(usdg.balanceOf(BORROWER), 505_000 * USDG_ONE, "cash not delivered");
        assertEq(credit.debtOf(BORROWER, address(nvda)), 5_000 * USDG_ONE, "debt not recorded");
        assertEq(nvda.balanceOf(address(credit)), 100e18, "collateral not held");
    }

    function test_cannotDrawBeyondCapacity() public {
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.NotHealthy.selector, BORROWER, address(nvda)));
        credit.borrowAgainst(address(nvda), 100e18, 9_000 * USDG_ONE);
    }

    function test_interestAccruesAndTheLenderEarnsIt() public {
        // 500 NVDA at $180 is $90,000, which at 65% LTV less the 25% halt buffer supports $43,875.
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 500e18, 40_000 * USDG_ONE);

        uint256 debtBefore = credit.debtOf(BORROWER, address(nvda));
        skip(365 days);
        credit.accrue();
        uint256 debtAfter = credit.debtOf(BORROWER, address(nvda));
        assertGt(debtAfter, debtBefore, "no interest accrued");

        // Utilisation is 4%, below the kink, so the rate is base + slope1 * u / kink
        // = 2% + 8% * 0.04/0.8 = 2.4%. Over a year on $40,000 that is about $960.
        assertApproxEqRel(debtAfter - debtBefore, 960 * USDG_ONE, 0.02e18, "rate model wrong");

        // And the supplier's claim grew by the same interest less the reserve factor.
        uint256 redeemable = (credit.supplySharesOf(LP) * (credit.cash() + credit.totalBorrows()))
            / credit.totalSupplyShares();
        assertGt(redeemable, 1_000_000 * USDG_ONE, "lender earned nothing");
    }

    function test_repayAndUnlockReturnsTheShares() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 5_000 * USDG_ONE);
        skip(30 days);

        // Reading the balance and then repaying it leaves dust, because `accrue` runs inside the
        // repayment and moves the number between the two calls. `max` is the only way to close a
        // position exactly, and every client in this repo uses it.
        vm.prank(BORROWER);
        credit.repayAndUnlock(address(nvda), type(uint256).max, 100e18);

        assertEq(credit.debtOf(BORROWER, address(nvda)), 0, "debt remains");
        assertEq(nvda.balanceOf(BORROWER), 500e18, "shares not returned");
    }

    function test_cannotUnlockCollateralThatIsHoldingUpDebt() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 8_000 * USDG_ONE);
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.NotHealthy.selector, BORROWER, address(nvda)));
        credit.repayAndUnlock(address(nvda), 0, 50e18);
    }

    // ------------------------------------------------------------ halts

    function test_liquidationIsImpossibleWhileHaltedAndTheFlagSurvivesIt() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 8_700 * USDG_ONE);

        // The stock falls far enough to breach.
        price.setPrice(address(nvda), 120 * PRICE_ONE);
        assertFalse(credit.isHealthy(BORROWER, address(nvda)), "should be unsafe");

        // A keeper flags it, then the issuer freezes the token.
        vm.prank(KEEPER);
        credit.flag(BORROWER, address(nvda));
        nvda.setTokenPaused(true);

        // Nobody can liquidate at any price, which is the whole problem this protocol prices.
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.PriceUnusable.selector, PriceStatus.TokenPaused));
        credit.liquidate(BORROWER, address(nvda), 1_000 * USDG_ONE);

        // The halt lifts. The flag is still there and the flagger is still paid.
        nvda.setTokenPaused(false);
        uint256 keeperBefore = nvda.balanceOf(KEEPER);
        vm.prank(LIQUIDATOR);
        credit.liquidate(BORROWER, address(nvda), 1_000 * USDG_ONE);
        assertGt(nvda.balanceOf(KEEPER), keeperBefore, "flagger not paid after the halt");
    }

    function test_cannotFlagAHealthyPosition() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 1_000 * USDG_ONE);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.StillHealthy.selector, BORROWER, address(nvda)));
        credit.flag(BORROWER, address(nvda));
    }

    function test_healthyPositionCannotBeLiquidated() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 1_000 * USDG_ONE);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.StillHealthy.selector, BORROWER, address(nvda)));
        credit.liquidate(BORROWER, address(nvda), 100 * USDG_ONE);
    }

    function test_liquidationSeizesTheBonusAndClearsTheDebt() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 8_700 * USDG_ONE);
        price.setPrice(address(nvda), 120 * PRICE_ONE);

        uint256 debtBefore = credit.debtOf(BORROWER, address(nvda));
        vm.prank(LIQUIDATOR);
        uint256 seized = credit.liquidate(BORROWER, address(nvda), 2_000 * USDG_ONE);

        assertEq(credit.debtOf(BORROWER, address(nvda)), debtBefore - 2_000 * USDG_ONE, "debt not reduced");
        // $2,000 of debt plus an 8% bonus is $2,160, which at $120 a share is 18 shares.
        assertApproxEqAbs(seized, 18e18, 1e15, "wrong seizure");
        assertEq(nvda.balanceOf(LIQUIDATOR), seized, "liquidator not paid");
    }

    function test_closeFactorCapsHowMuchOneLiquidationTakes() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 8_700 * USDG_ONE);
        price.setPrice(address(nvda), 120 * PRICE_ONE);

        uint256 owed = credit.debtOf(BORROWER, address(nvda));
        vm.prank(LIQUIDATOR);
        credit.liquidate(BORROWER, address(nvda), owed);
        // Half the debt at most, so a single liquidation never takes the whole position.
        assertApproxEqAbs(credit.debtOf(BORROWER, address(nvda)), owed / 2, 1, "close factor ignored");
    }

    function test_supplierCannotRedeemMoreCashThanExists() public {
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 500e18, 40_000 * USDG_ONE);
        uint256 shares = credit.supplySharesOf(LP);
        vm.prank(LP);
        vm.expectRevert();
        credit.redeem(shares);
        // But redeeming what is actually free works.
        vm.prank(LP);
        credit.redeem(shares / 2);
    }

    function test_notionalIsBookedAndReleasedAgainstTheSharedCap() public {
        uint256 before = registry.openNotional(address(nvda));
        vm.prank(BORROWER);
        credit.borrowAgainst(address(nvda), 100e18, 5_000 * USDG_ONE);
        assertEq(registry.openNotional(address(nvda)) - before, 5_000 * PRICE_ONE, "not booked");

        skip(10 days);
        vm.prank(BORROWER);
        credit.repayAndUnlock(address(nvda), type(uint256).max, 0);
        // Interest repaid above principal was never booked, so it is not released either.
        assertEq(registry.openNotional(address(nvda)), before, "cap drifted");
    }
}
