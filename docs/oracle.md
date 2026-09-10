# Pricing an equity on a chain with no oracle

There is no price feed on Robinhood Chain. No Chainlink, no Pyth, no first-party publisher. There is
a Uniswap v3 deployment with real depth in USDG pairs, and an issuer publishing halt flags.
`EquityOracle` is what those two facts add up to.

## What it refuses to do is the point

A feed for an ordinary ERC-20 has one failure mode: a stale or manipulated price. An equity here has
four more, and each is a distinct `PriceStatus` rather than a number that quietly keeps being
served.

| Status | When | Why it matters |
|---|---|---|
| `TokenPaused` | the issuer froze transfers | Nothing can be seized, delivered or settled, so serving a price would let a protocol take an action it cannot complete. |
| `IssuerOraclePaused` | the issuer disavowed the price, transfers still work | The market may keep trading. This contract will not say what it thinks that means. |
| `MultiplierTransition` | a corporate action is scheduled inside the blackout | The pool prices raw units and the multiplier is about to change what a raw unit *is*, so the window spans two different definitions of the asset. |
| `TwapDeviation` | the window average and the current tick disagree beyond the band | What a manipulation attempt looks like from inside the pool. |
| `TwapUnavailable` | `observe` failed over the window | The observation ring cannot reach back that far. |

A caller gets `tryValueOf` (value plus reason) or `valueOf` (value or revert). Products use the first
wherever a refusal should not condemn a position: `CreditLine.isHealthy` returns `true` when the
price is unusable, because a price the oracle will not serve cannot be the basis for liquidating
someone.

## Why a TWAP rather than the current tick

Depth on these pools is a cliff, not a slope. A single large enough swap takes the price from
unchanged to collapsed with very little in between. A window average makes that attack cost the
attacker the whole window rather than one block, and the deviation guard turns the attempt into a
refusal instead of a bad print.

## The unit, stated precisely

The easiest thing in this contract to get wrong by six or twelve orders of magnitude while still
returning a plausible number.

A pool tick encodes `1.0001^tick` = raw token1 per raw token0. Equities are 18 decimals and USDG is
6. For NVDA at $180 the raw ratio is 5.56e9 (tick 224392); the wad-scaled inverse is exactly 1.8e8;
which becomes 1.8e10 at the protocol's 1e8 dollar unit. Every intermediate in `_priceFromTick` was
checked against those figures, and `test_oraclePricesNvdaFromTheLivePool` bounds the result to a
plausible share price so a decimal slip fails loudly.

`powWad` is used rather than Uniswap's `TickMath`. At these magnitudes its relative error is around
2e-13, a hundred thousand times finer than the deviation band the caller is about to apply, and it
replaces several hundred lines of assembly.

## Swapping it back out

`ISwapVenue` is an interface rather than a hardcoded router, because Robinhood Chain's
UniversalRouter is a modified build whose swap inputs carry an extra `uint256[] minHopPriceX36`
argument, so a standard encoding reverts with `SliceOutOfBounds()`. `UniswapV3Venue` targets
`SwapRouter02` instead, whose `exactInputSingle` carries no deadline argument. A venue that turns
out to differ from its mainnet namesake should cost one adapter, not a change to the vault holding
LP capital.
