// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AssetRegistry, AssetConfig} from "../src/core/AssetRegistry.sol";
import {EquityOracle, FeedConfig} from "../src/core/EquityOracle.sol";
import {VolSurface} from "../src/paid/VolSurface.sol";
import {PaidOrders} from "../src/paid/PaidOrders.sol";
import {UnderwriterVault} from "../src/paid/UnderwriterVault.sol";
import {UniswapV3Venue} from "../src/paid/UniswapV3Venue.sol";
import {CreditLine} from "../src/credit/CreditLine.sol";
import {TermRepo} from "../src/savings/TermRepo.sol";
import {AccrualStrip} from "../src/strip/AccrualStrip.sol";

/// @notice Deploys the whole system and wires it, in the order the wiring requires.
///
/// @dev The order is load-bearing in one place and one only: `UnderwriterVault` takes the
///      `PaidOrders` address in its constructor and `PaidOrders` takes the vault as a buyer
///      afterwards, so the venue must exist before the vault and the vault must be registered after
///      both. Everything else is independent.
///
///      Assets are configured from `data/assets.json` by `scripts/deploy.mjs`, which passes them in
///      rather than having this script hardcode a list that would rot. A deployment with no assets
///      configured is a valid intermediate state: nothing can be written against a ticker the
///      registry has never heard of.
contract Deploy is Script {
    struct Addresses {
        address registry;
        address oracle;
        address volSurface;
        address paidOrders;
        address underwriterVault;
        address swapVenue;
        address creditLine;
        address termRepo;
        address accrualStrip;
    }

    function run() external returns (Addresses memory out) {
        address owner = vm.envOr("MARIAN_OWNER", msg.sender);
        address usdg = vm.envAddress("USDG_ADDRESS");
        address router = vm.envAddress("SWAP_ROUTER_02");
        address feeSink = vm.envOr("FEE_SINK", owner);
        uint8 usdgDecimals = uint8(vm.envOr("USDG_DECIMALS", uint256(6)));

        vm.startBroadcast();

        AssetRegistry registry = new AssetRegistry(owner);
        EquityOracle oracle = new EquityOracle(owner, usdg, usdgDecimals);
        VolSurface volSurface = new VolSurface(owner);

        PaidOrders paidOrders =
            new PaidOrders(owner, address(registry), address(oracle), address(volSurface), usdg, feeSink);
        UnderwriterVault vault = new UnderwriterVault(
            owner, address(paidOrders), address(registry), address(volSurface), address(oracle), usdg
        );
        UniswapV3Venue venue = new UniswapV3Venue(owner, router, usdg);

        CreditLine credit = new CreditLine(owner, address(registry), address(oracle), usdg);
        TermRepo termRepo = new TermRepo(owner, address(registry), address(oracle), usdg);
        AccrualStrip strip = new AccrualStrip(owner, address(registry), usdg, feeSink);

        // Only contracts that move the shared notional cap are registered as products. The strip
        // does not: locking shares that are already yours takes no new risk on the ticker.
        registry.setProduct(address(paidOrders), true);
        registry.setProduct(address(credit), true);

        paidOrders.setBuyer(address(vault), true);
        vault.setSwapVenue(address(venue));

        vm.stopBroadcast();

        out = Addresses({
            registry: address(registry),
            oracle: address(oracle),
            volSurface: address(volSurface),
            paidOrders: address(paidOrders),
            underwriterVault: address(vault),
            swapVenue: address(venue),
            creditLine: address(credit),
            termRepo: address(termRepo),
            accrualStrip: address(strip)
        });

        console2.log("registry        ", out.registry);
        console2.log("oracle          ", out.oracle);
        console2.log("volSurface      ", out.volSurface);
        console2.log("paidOrders      ", out.paidOrders);
        console2.log("underwriterVault", out.underwriterVault);
        console2.log("swapVenue       ", out.swapVenue);
        console2.log("creditLine      ", out.creditLine);
        console2.log("termRepo        ", out.termRepo);
        console2.log("accrualStrip    ", out.accrualStrip);
    }
}
