# Measurements

Every claim this repository makes about Robinhood Chain, and the command that re-derives it.

Nothing here was taken on trust from a block explorer or a third-party list. Where a number appears
in a contract comment, a test, or the app, it came from one of the scripts below.

## Re-deriving everything

```bash
node scripts/refresh-assets.mjs    # verifies every ticker and pool -> data/assets.json
node scripts/measure-accrual.mjs   # reconstructs payout history  -> data/accrual.json
RHC_RPC_URL=https://rpc-robinhood.blockmachine.io pnpm fork:test   # asserts the findings on chain
```

## The chain

| Fact | Value | How |
|---|---|---|
| Chain id | 4663 (testnet 46630) | `eth_chainId` |
| Block time | ~0.193s average over the chain's life | genesis and head timestamps |
| Age at time of writing | 133 days | same |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, **6 decimals**, no EIP-2612, no EIP-3009 | `decimals()`, asserted in `test_usdgIsSixDecimals` |
| Shared `Stock` implementation | `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` | all 254 equities are beacon proxies onto it |
| Price oracle | **none exists** | no Chainlink, no Pyth, no first-party feed |

**Archive access matters and not every endpoint has it.** `robinhood-rpc.publicnode.com` serves only
the tip and rejects older blocks as archive requests, *inside a batch, as a null result rather than
an error*. `scripts/rpc.mjs` keeps a separate `ARCHIVE_RPCS` list for that reason: a historical
sweep that includes the wrong endpoint comes back full of holes that read as "this contract did not
exist yet", which is how a token whose payout landed yesterday gets recorded as having never paid.

## Tokenized equities

38 tickers have a USDG pool deep enough to price and settle against. All were verified: the pool
really is that equity against USDG, in the stored token order, with a fee tier and an observation
ring large enough for a thirty-minute average. All are 18 decimals.

Getting the token order wrong is the one misconfiguration that produces a plausible wrong number
instead of an error, so `EquityOracle.configure` refuses a pair whose `token0`/`token1` do not match
what the caller claimed, and `test_oracleRefusesAPairItWasMisconfiguredFor` proves it against the
live NVDA pool.

## Distributions are multiplier steps

The finding the payout strip rests on. Read on 2026-09-10 across all 38:

**Exactly 8 tickers sit above `1e18`, and they are exactly the 8 that pay a distribution.**
**Every other ticker sits at exactly `1e18`, to the wei.**

| Ticker | Payout steps seen | Window | Cumulative | Annualised |
|---|---|---|---|---|
| SGOV | 3 | 131d | 51.02 bps | 1.42% |
| UPS | 1 | 131d | 22.09 bps | 0.62% |
| NVDA | 1 | 131d | 7.75 bps | 0.22% |
| COST | 1 | 128.7d | 6.12 bps | 0.17% |
| AAPL | 1 | 131d | 5.66 bps | 0.16% |
| MU | 1 | 131d | 0.75 bps | 0.02% |
| DELL | 1 | 131d | 0.64 bps | 0.02% |
| JNJ | 1 | 84.4d | 0.21 bps | 0.01% |

Non-payers at exactly `1e18` include TSLA, META, GLD, GME, SPY, QQQ and 24 others.
`test_nonPayersSitAtExactlyOne` asserts four of them on chain, and
`test_dividendPayersCarryAMultiplierAboveOne` asserts four of the payers.

### The unflattering half

**What these tokens pass through on chain is materially less than the dividend the underlying pays
in the world.** SGOV annualises here at 1.42% against a T-bill yield several times that. JNJ's
on-chain accrual over a quarter is a rounding error next to its actual dividend.

This repository does not explain that gap, because nothing on chain explains it. What it does is
refuse to paper over it: the payouts page shows the measured column and says plainly that it is not
a way to buy a company's dividend yield, and `scripts/measure-accrual.mjs` reports the observation
window alongside every rate so an annualised figure can never be read without it.

## Uniswap v3

The venue used for pricing and for turning settled shares back into dollars.

| | |
|---|---|
| Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| NVDA/USDG 0.05% | `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3`, USDG is token0, cardinality 6000 |
| SPY/USDG 0.05% | `0xa7Bb1AC63BBaB0C44316E6c8C455213441689167`, SPY is token0, cardinality 1801 |

**`slot0` returns seven values, not six.** `feeProtocol` sits between the cardinality fields and
`unlocked`. This is standard Uniswap v3 and it is easy to mis-declare, because omitting it does not
produce an error that names the problem: the call succeeds, the ABI decoder reverts bare, and a
trace shows the pool returning correct data immediately before an `EvmError: Revert` with no
message. The raw return is 224 bytes. Verified directly, and pinned by
`test_poolsAreTheDocumentedPairsAndStoreEnoughObservations`.

## Function selectors

Three of the `Stock` selectors are not what an obvious guess produces:

| Function | Selector |
|---|---|
| `uiMultiplier()` | `0xa60bf13d` |
| `newUIMultiplier()` | `0xdc767007` |
| `effectiveAt()` | `0x97a4064f` |
| `oraclePaused()` | `0x7706ba52` |
| `paused()` | `0x5c975abb` |

A wrong selector returns empty data rather than reverting, which downstream reads as "this token has
no such field". `scripts/rpc.mjs` therefore derives them with viem's `toFunctionSelector` rather
than pinning them, so they cannot rot and cannot be typed wrong.
