// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISwapVenue
/// @notice Turning a settled call's share payoff back into dollars.
///
/// @dev Behind an interface on purpose. Robinhood Chain's UniversalRouter is a modified build whose
///      swap inputs carry an extra `uint256[] minHopPriceX36` argument, so a standard encoding
///      reverts with `SliceOutOfBounds()`. A venue that turns out to differ from its mainnet
///      namesake should cost one adapter, not a change to the vault that holds LP capital.
interface ISwapVenue {
    /// @notice Sell `amountIn` raw units of `asset` for at least `minOut` USDG, to `recipient`.
    function sellForUsdg(address asset, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut);
}
