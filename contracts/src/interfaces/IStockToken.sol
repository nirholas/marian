// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title The surface every Robinhood tokenized equity exposes.
/// @notice All 254 tokenized equities on Robinhood Chain (eip155:4663) are beacon proxies onto one
///         shared `Stock` implementation, so this interface describes every one of them exactly.
///         Three of its members have no analogue on an ordinary ERC-20, and each one changes how a
///         derivative on this asset has to be written:
///
///         * `uiMultiplier()` scales raw units into economic shares. It is the chain's corporate
///           action channel: a split, a reverse split and a dividend all arrive as a change to this
///           number and to nothing else. Measured on 2026-09-10, every one of the 30 non-dividend
///           names on this chain sits at exactly 1e18 while all 8 dividend payers sit above it, so
///           this is also the only place a payout is observable.
///
///         * `newUIMultiplier()` / `effectiveAt()` publish the *next* value ahead of time. A
///           derivative written here can therefore adjust its own strike before the corporate
///           action lands rather than after it, which is the thing options exchanges do by memo and
///           by hand.
///
///         * `paused()` is the issuer's halt. While it is true every transfer, approve and permit
///           reverts, so collateral cannot move at all. `oraclePaused()` is the weaker signal: the
///           issuer disavowing the price while transfers still work.
interface IStockToken {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    /// @notice Economic shares per 1e18 raw units. 1e18 means one raw unit is exactly one share.
    function uiMultiplier() external view returns (uint256);
    /// @notice The multiplier that becomes live at `effectiveAt()`.
    function newUIMultiplier() external view returns (uint256);
    /// @notice Unix second at which `newUIMultiplier()` takes over. Zero when never scheduled.
    function effectiveAt() external view returns (uint256);
    /// @notice `balanceOf` already scaled by the live multiplier.
    function balanceOfUI(address account) external view returns (uint256);

    /// @notice True when transfers are frozen, by this token or by the chain-wide registry.
    function paused() external view returns (bool);
    /// @notice True when only this token is frozen, ignoring the registry-wide switch.
    function tokenPaused() external view returns (bool);
    /// @notice True when the issuer has disavowed this token's price. Transfers may still work.
    function oraclePaused() external view returns (bool);
}
