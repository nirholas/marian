// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ISwapVenue} from "./ISwapVenue.sol";
import {IERC20} from "../interfaces/IERC20.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapV3Venue
/// @notice Sells a settled call's share payoff into the deepest USDG pool for that ticker.
///
/// @dev Uses `SwapRouter02.exactInputSingle`, which unlike the v1 router carries no deadline
///      argument. The pool fee tier is configured per asset rather than searched, because searching
///      means quoting several pools inside a transaction that is already holding LP capital, and
///      the deepest tier for each of these pairs is a fact that changes on the timescale of months.
///
///      `minOut` is supplied by the caller and enforced by the router. This contract deliberately
///      has no opinion about slippage: the vault knows what the position was marked at and is the
///      only party that can say what an acceptable execution is.
contract UniswapV3Venue is ISwapVenue, Ownable {
    using SafeTransferLib for address;

    ISwapRouter02 public immutable ROUTER;
    address public immutable USDG;

    mapping(address => uint24) public feeTierOf;

    event FeeTierSet(address indexed asset, uint24 fee);

    error NoRoute(address asset);
    error Shortfall(uint256 received, uint256 minOut);

    constructor(address owner_, address router, address usdg) {
        _initializeOwner(owner_);
        ROUTER = ISwapRouter02(router);
        USDG = usdg;
    }

    function setFeeTier(address asset, uint24 fee) external onlyOwner {
        require(fee == 100 || fee == 500 || fee == 3_000 || fee == 10_000, "Venue: bad fee tier");
        feeTierOf[asset] = fee;
        emit FeeTierSet(asset, fee);
    }

    /// @inheritdoc ISwapVenue
    function sellForUsdg(address asset, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        uint24 fee = feeTierOf[asset];
        if (fee == 0) revert NoRoute(asset);

        asset.safeTransferFrom(msg.sender, address(this), amountIn);
        asset.safeApprove(address(ROUTER), amountIn);
        amountOut = ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: asset,
                tokenOut: USDG,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        // The router enforces `amountOutMinimum` itself, but a router that is not the one this
        // contract thinks it is would not. Checking here costs one comparison.
        if (amountOut < minOut) revert Shortfall(amountOut, minOut);
        asset.safeApprove(address(ROUTER), 0);
    }
}
