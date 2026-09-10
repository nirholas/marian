// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A series' economic terms, passed to buyers explicitly.
/// @dev Passed rather than looked up so a buyer can quote a series that does not exist yet. The
///      first writer of a strike is the one who most needs to see a price before committing, and a
///      buyer that could only quote series already on chain would leave exactly that user with a
///      blank screen.
struct SeriesTerms {
    address asset;
    uint64 expiry;
    bool isCall;
    uint256 strikePerShare1e8;
}

/// @title IOptionBuyer
/// @notice The other side of the trade.
///
/// @dev A retail writer presses one button and expects a dollar amount. Someone has to be standing
///      there to pay it. This interface is that someone, and keeping it an interface rather than a
///      single hard-wired counterparty is the whole market design: `PaidOrders` polls every
///      registered buyer and routes the writer to the best bid, so a professional vol desk that
///      deploys its own implementation immediately competes with the protocol's own vault and the
///      writer keeps the difference. The vault is the floor under the market, not the market.
interface IOptionBuyer {
    /// @notice What this buyer would pay, in USDG, for `qtyRaw` of the long side.
    /// @dev Must not revert. A buyer that cannot or will not quote returns zero, because a router
    ///      that has to try/catch every venue on every quote is a router that breaks when one venue
    ///      is misconfigured.
    function quoteBuy(bytes32 id, SeriesTerms calldata terms, uint256 qtyRaw)
        external
        view
        returns (uint256 premiumUsdg);

    /// @notice Take the long side, paying `premiumUsdg` to the caller before returning.
    /// @dev Only ever called by `PaidOrders`, which verifies the transfer landed rather than
    ///      trusting the return value.
    function executeBuy(bytes32 id, SeriesTerms calldata terms, uint256 qtyRaw, uint256 premiumUsdg) external;
}
