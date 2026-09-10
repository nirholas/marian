// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev `slot0` returns SEVEN values, not six. `feeProtocol` sits between the cardinality fields
///      and `unlocked`, and omitting it does not produce a decode error that names the problem: the
///      call succeeds, the ABI decoder reverts bare, and a trace shows the pool returning correct
///      data immediately before an `EvmError: Revert` with no message. Verified against the live
///      NVDA/USDG pool, whose raw `slot0` return is 224 bytes.
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}
