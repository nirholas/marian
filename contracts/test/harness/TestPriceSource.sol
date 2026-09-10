// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceSource, PriceStatus} from "../../src/interfaces/IPriceSource.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title TestPriceSource
/// @notice A price source whose *price* is set by the test but whose *refusals* are the real ones.
///
/// @dev The halt logic here is not simplified: it reads the same `paused`, `oraclePaused` and
///      scheduled-multiplier state from the token that `EquityOracle` reads, and returns the same
///      `PriceStatus` values. Only the number is injected, because the alternative is standing up a
///      Uniswap pool with a populated observation ring inside every unit test, which would test
///      Uniswap rather than this protocol. `EquityOracle`'s own derivation is covered against the
///      live chain in `test/Fork.t.sol`.
contract TestPriceSource is IPriceSource {
    /// @dev Dollar price of one whole token, at 1e8.
    mapping(address => uint256) public priceOf;
    mapping(address => bool) public configured;
    uint256 public pokes;

    function setPrice(address asset, uint256 price1e8) external {
        priceOf[asset] = price1e8;
        configured[asset] = true;
    }

    function valueOf(address asset, uint256 rawAmount) external view returns (uint256) {
        (uint256 value, bool ok, PriceStatus status) = tryValueOf(asset, rawAmount);
        require(ok, string.concat("TestPriceSource: unusable ", _statusName(status)));
        return value;
    }

    function tryValueOf(address asset, uint256 rawAmount)
        public
        view
        returns (uint256 usd1e8, bool ok, PriceStatus status)
    {
        if (!configured[asset]) return (0, false, PriceStatus.NoConfig);
        IStockToken stock = IStockToken(asset);
        if (stock.paused()) return (0, false, PriceStatus.TokenPaused);
        if (stock.oraclePaused()) return (0, false, PriceStatus.IssuerOraclePaused);
        uint256 at = stock.effectiveAt();
        if (at > block.timestamp && stock.newUIMultiplier() != stock.uiMultiplier()) {
            return (0, false, PriceStatus.MultiplierTransition);
        }
        return (FixedPointMathLib.fullMulDiv(rawAmount, priceOf[asset], 1e18), true, PriceStatus.OK);
    }

    function poke(address) external {
        pokes++;
    }

    function _statusName(PriceStatus status) internal pure returns (string memory) {
        if (status == PriceStatus.NoConfig) return "NoConfig";
        if (status == PriceStatus.TokenPaused) return "TokenPaused";
        if (status == PriceStatus.IssuerOraclePaused) return "IssuerOraclePaused";
        if (status == PriceStatus.MultiplierTransition) return "MultiplierTransition";
        return "other";
    }
}
