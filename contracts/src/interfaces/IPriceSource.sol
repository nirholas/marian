// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Why a price is or is not usable. Anything other than `OK` means no new risk may be
///         opened against the asset and no settlement may be finalised on it.
enum PriceStatus {
    OK,
    NoConfig,
    NoQuote,
    QuoteStale,
    TokenPaused,
    IssuerOraclePaused,
    TwapUnavailable,
    TwapDeviation,
    MultiplierTransition,
    BasketDegraded
}

/// @title The only thing this protocol needs from an oracle.
/// @notice Two functions on purpose. A risk engine needs a value it can act on, and a reason when
///         it cannot get one. Everything about how the value is formed (a pool TWAP, an attested
///         quote, a reporter quorum, a corporate-action blackout) belongs behind this line.
///         `SherwoodPriceSource` implements it against the Sherwood oracle, which is the only
///         equity price feed on Robinhood Chain; any other feed that can answer these two questions
///         honestly can be dropped in without touching a product contract.
interface IPriceSource {
    /// @notice Dollar value of `rawAmount` raw units of `asset`, at 1e8. Reverts unless usable.
    function valueOf(address asset, uint256 rawAmount) external view returns (uint256 usd1e8);

    /// @notice The same value, with a reason instead of a revert when it cannot be served.
    function tryValueOf(address asset, uint256 rawAmount)
        external
        view
        returns (uint256 usd1e8, bool ok, PriceStatus status);

    /// @notice Let the feed checkpoint anything it needs before a risk decision is taken against it.
    function poke(address asset) external;
}
