// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PriceStatus} from "./IPriceSource.sol";

/// @notice The Sherwood halt-aware equity oracle, as this protocol consumes it.
interface ISherwoodOracle {
    function valueOf(address asset, uint256 rawAmount) external view returns (uint256 usd1e8);
    function tryValueOf(address asset, uint256 rawAmount)
        external
        view
        returns (uint256 usd1e8, bool ok, PriceStatus status);
    function poke(address asset) external;
}
