// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry, AssetConfig} from "../src/core/AssetRegistry.sol";
import {PaidOrders, Series} from "../src/paid/PaidOrders.sol";
import {UnderwriterVault} from "../src/paid/UnderwriterVault.sol";
import {VolSurface} from "../src/paid/VolSurface.sol";
import {SeriesTerms} from "../src/paid/IOptionBuyer.sol";

import {TestStock} from "./harness/TestStock.sol";
import {TestUsdg} from "./harness/TestUsdg.sol";
import {TestPriceSource} from "./harness/TestPriceSource.sol";

/// @notice Shared fixture. Numbers are chosen to look like the live chain rather than to be round:
///         NVDA at $180 with 18 decimals, USDG at 6, a 45% vol with the ordinary equity skew.
abstract contract Base is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant WRITER = address(0xB0B);
    address internal constant LP = address(0xC0FFEE);
    address internal constant KEEPER = address(0xDEED);
    address internal constant FEE_SINK = address(0xFEE5);

    uint256 internal constant USDG_ONE = 1e6;
    uint256 internal constant PRICE_ONE = 1e8;

    TestStock internal nvda;
    TestUsdg internal usdg;
    TestPriceSource internal price;
    AssetRegistry internal registry;
    VolSurface internal vol;
    PaidOrders internal book;
    UnderwriterVault internal vault;

    function setUp() public virtual {
        // Start well past the expiry epoch so the weekly grid has usable dates ahead of it.
        vm.warp(1_789_000_000);

        nvda = new TestStock("NVIDIA Robinhood Token", "NVDA");
        usdg = new TestUsdg();
        price = new TestPriceSource();
        price.setPrice(address(nvda), 180 * PRICE_ONE);

        vm.startPrank(OWNER);
        registry = new AssetRegistry(OWNER);
        vol = new VolSurface(OWNER);
        book = new PaidOrders(OWNER, address(registry), address(price), address(vol), address(usdg), FEE_SINK);
        vault = new UnderwriterVault(OWNER, address(book), address(registry), address(vol), address(price), address(usdg));

        registry.configure(address(nvda), _defaultConfig());
        registry.setProduct(address(book), true);
        book.setBuyer(address(vault), true);
        book.setRate(0.04e18);
        vol.setReporter(OWNER, true);
        vol.post(address(nvda), 0.45e18, -0.6e18);
        vault.setLimits(2_000, 500, 250_000 * USDG_ONE, 2_000_000 * USDG_ONE, 3_000);
        vault.setKeeper(KEEPER, true);
        vm.stopPrank();

        usdg.mint(LP, 5_000_000 * USDG_ONE);
        vm.startPrank(LP);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 * USDG_ONE);
        vm.stopPrank();

        nvda.mint(WRITER, 1_000e18);
        usdg.mint(WRITER, 1_000_000 * USDG_ONE);
        vm.startPrank(WRITER);
        nvda.approve(address(book), type(uint256).max);
        usdg.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    function _defaultConfig() internal pure returns (AssetConfig memory) {
        return AssetConfig({
            enabled: true,
            haltBufferBps: 2_500,
            strikeBandBps: 5_000,
            maxLtvBps: 6_500,
            minTenor: 1 days,
            maxTenor: 120 days,
            maxOpenNotionalUsd1e8: uint128(50_000_000 * PRICE_ONE),
            feeBps: 100
        });
    }

    /// @notice The first weekly expiry at least `minSeconds` away.
    function _nextExpiry(uint256 minSeconds) internal view returns (uint64) {
        uint64 epoch = book.EXPIRY_EPOCH();
        uint64 period = book.EXPIRY_PERIOD();
        uint64 target = uint64(block.timestamp + minSeconds);
        uint64 elapsed = target > epoch ? target - epoch : 0;
        return epoch + ((elapsed / period) + 1) * period;
    }

    function _terms(bool isCall, uint256 strikePerShare1e8, uint64 expiry) internal view returns (SeriesTerms memory) {
        return SeriesTerms({
            asset: address(nvda),
            expiry: expiry,
            isCall: isCall,
            strikePerShare1e8: strikePerShare1e8
        });
    }
}
