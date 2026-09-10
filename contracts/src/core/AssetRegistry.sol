// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";

/// @notice Per-asset risk parameters. Every product in this repo reads the same struct, so an asset
///         that is too thin to write options on is also too thin to lend against.
struct AssetConfig {
    /// @dev False disables new risk immediately. Existing positions always keep their exit path.
    bool enabled;
    /// @dev Extra margin held against the possibility that the issuer halts the token and no
    ///      collateral can move at all. Priced per asset, because a halt is an option the issuer
    ///      holds and its value is not the same for SPY as for a single small-cap name.
    uint16 haltBufferBps;
    /// @dev How far from spot a strike may be placed, each way. Stops a user writing a strike so
    ///      far out that the premium rounds to dust, or so far in that the option is a spot sale
    ///      wearing an option's clothes.
    uint16 strikeBandBps;
    /// @dev Loan-to-value ceiling for the credit line, before the halt buffer is subtracted.
    uint16 maxLtvBps;
    /// @dev Shortest and longest life of a new series, in seconds.
    uint32 minTenor;
    uint32 maxTenor;
    /// @dev Ceiling on live notional across all products, in USD at 1e8. Sized from measured pool
    ///      depth rather than conviction: what a hedger could actually trade on this chain is the
    ///      only number that makes the risk real.
    uint128 maxOpenNotionalUsd1e8;
    /// @dev Protocol take on premium, in basis points.
    uint16 feeBps;
}

/// @title AssetRegistry
/// @notice The single place that answers "may this protocol take risk on this ticker, and how
///         much".
///
/// @dev **Why one registry across four products.** Marian runs a covered-call venue, a credit
///      line, a term repo and an accrual strip against the same 254 tokenized equities. Every one
///      of them is exposed to the same two facts about a ticker: how deep it trades on this chain,
///      and how likely the issuer is to freeze it. Keeping those facts in one contract means a
///      parameter change is one transaction with one audit trail, and it makes the incoherent
///      state impossible: an asset cannot be conservative enough to lend against but reckless
///      enough to write options on.
contract AssetRegistry is Ownable {
    mapping(address => AssetConfig) private _configs;
    address[] private _listed;
    mapping(address => bool) private _isListed;

    /// @dev Live notional per asset, in USD at 1e8, summed across every product that reports.
    mapping(address => uint256) public openNotional;
    /// @dev Contracts allowed to move `openNotional`. Products, not users.
    mapping(address => bool) public isProduct;

    event AssetConfigured(address indexed asset, AssetConfig config);
    event ProductSet(address indexed product, bool allowed);
    event NotionalChanged(address indexed asset, address indexed product, int256 deltaUsd1e8, uint256 total);

    error NotAProduct();
    error AssetDisabled(address asset);
    error NotionalCapExceeded(address asset, uint256 attempted, uint256 cap);
    error BadConfig(string field);

    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    modifier onlyProduct() {
        if (!isProduct[msg.sender]) revert NotAProduct();
        _;
    }

    function setProduct(address product, bool allowed) external onlyOwner {
        isProduct[product] = allowed;
        emit ProductSet(product, allowed);
    }

    function configure(address asset, AssetConfig calldata config) external onlyOwner {
        if (config.haltBufferBps > 5000) revert BadConfig("haltBufferBps");
        if (config.strikeBandBps == 0 || config.strikeBandBps > 20000) revert BadConfig("strikeBandBps");
        if (config.maxLtvBps > 9000) revert BadConfig("maxLtvBps");
        if (config.minTenor == 0 || config.minTenor > config.maxTenor) revert BadConfig("tenor");
        if (config.feeBps > 2000) revert BadConfig("feeBps");
        // A token that does not answer `uiMultiplier` is not a Robinhood tokenized equity, and
        // every strike in this system is denominated against that number. Finding out at listing
        // time is free; finding out at settlement is not.
        require(IStockToken(asset).uiMultiplier() != 0, "AssetRegistry: not a stock token");

        _configs[asset] = config;
        if (!_isListed[asset]) {
            _isListed[asset] = true;
            _listed.push(asset);
        }
        emit AssetConfigured(asset, config);
    }

    function configOf(address asset) external view returns (AssetConfig memory) {
        return _configs[asset];
    }

    /// @notice Reverts unless the asset is live. Products call this before taking any new risk.
    function requireEnabled(address asset) external view returns (AssetConfig memory config) {
        config = _configs[asset];
        if (!config.enabled) revert AssetDisabled(asset);
    }

    function listed() external view returns (address[] memory) {
        return _listed;
    }

    function listedCount() external view returns (uint256) {
        return _listed.length;
    }

    /// @notice Book new live notional against an asset, or release it.
    /// @dev Signed on purpose. A product that opens and closes risk calls one function with one
    ///      sign convention, which is harder to get wrong than a matched pair of add/remove calls
    ///      that can drift apart when an exit path reverts halfway.
    function adjustNotional(address asset, int256 deltaUsd1e8) external onlyProduct {
        uint256 current = openNotional[asset];
        uint256 next;
        if (deltaUsd1e8 >= 0) {
            next = current + uint256(deltaUsd1e8);
            uint256 cap = _configs[asset].maxOpenNotionalUsd1e8;
            if (next > cap) revert NotionalCapExceeded(asset, next, cap);
        } else {
            uint256 shrink = uint256(-deltaUsd1e8);
            // Releasing more than was booked means two products disagree about what is open.
            // Flooring at zero would hide that permanently, so it underflows and reverts instead.
            next = current - shrink;
        }
        openNotional[asset] = next;
        emit NotionalChanged(asset, msg.sender, deltaUsd1e8, next);
    }

    /// @notice Headroom left under this asset's cap, in USD at 1e8.
    function headroom(address asset) external view returns (uint256) {
        uint256 cap = _configs[asset].maxOpenNotionalUsd1e8;
        uint256 used = openNotional[asset];
        return cap > used ? cap - used : 0;
    }
}
