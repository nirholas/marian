// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISwapVenue} from "../../src/paid/ISwapVenue.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IMintableUsdg {
    function mint(address to, uint256 value) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ITransferable {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @notice A venue that fills at the oracle price with a configurable slippage, so vault harvest
///         paths can be tested without standing up a Uniswap pool. The production venue is
///         `UniswapV3Venue`, exercised against the live chain in `test/Fork.t.sol`.
contract TestSwapVenue is ISwapVenue {
    IPriceSource public immutable PRICE;
    address public immutable USDG;
    uint256 public immutable USDG_SCALE;
    uint256 public slippageBps;

    constructor(address price, address usdg, uint256 usdgScale) {
        PRICE = IPriceSource(price);
        USDG = usdg;
        USDG_SCALE = usdgScale;
    }

    function setSlippageBps(uint256 bps) external {
        slippageBps = bps;
    }

    function sellForUsdg(address asset, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        ITransferable(asset).transferFrom(msg.sender, address(this), amountIn);
        uint256 usd1e8 = PRICE.valueOf(asset, amountIn);
        amountOut = FixedPointMathLib.fullMulDiv(usd1e8, USDG_SCALE, 1e8);
        amountOut = (amountOut * (10_000 - slippageBps)) / 10_000;
        require(amountOut >= minOut, "TestSwapVenue: slippage");
        IMintableUsdg(USDG).mint(recipient, amountOut);
    }
}
