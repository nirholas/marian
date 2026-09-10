# Payout strips

> Take the payouts your shares will earn over the next few months as cash today, and keep the shares.

## The measurement this rests on

On Robinhood Chain a distribution is a step in `uiMultiplier` and nothing else. Read across all 38
liquid tickers on 2026-09-10: exactly 8 sit above `1e18` and they are exactly the 8 that pay a
distribution; every other one sits at exactly `1e18`, to the wei. Sampled backwards through the
chain's whole history, each is a step function that moves once per payout and never falls.

Full table and method in [`measurements.md`](measurements.md).

That makes a payout strippable in the most literal way available anywhere in DeFi.

## Settlement needs no price at all

A holder locks `qtyRaw` raw units at multiplier `m0`. At maturity the multiplier is `m1`.

```
buyerRaw  = qtyRaw * (m1 - m0) / m1
holderRaw = qtyRaw - buyerRaw
```

The holder's remainder carries `qtyRaw * m0 / m1 * m1 = qtyRaw * m0` economic shares: **exactly what
they started with**. The buyer has the accrual. No oracle, no price, no counterparty solvency
entered the calculation.

A reverse split moves `m1` below `m0` and pays the buyer nothing, which is correct: a reverse split
is not a payout. `test_reverseSplitPaysTheBuyerNothing`.

Because no price is involved, **a halt changes when a strip settles and not by a single wei what it
settles for**. It is the only product in this repository with that property, and
`test_haltDelaysSettlementButNotItsOutcome` proves it by capturing the expected payout before the
freeze and comparing after.

## Being honest about the size

The accrual these tokens pass through on chain is **materially less than the dividend the underlying
company pays in the world**. SGOV annualises at 1.42% against a T-bill yield several times that.
JNJ's on-chain accrual over a quarter is a rounding error next to its actual dividend.

So the interface quotes the measurement and not a projection. `scripts/measure-accrual.mjs`
reconstructs each ticker's history from archive reads and reports the observation window alongside
every rate, so an annualised figure can never be read without the window it came from. The payouts
page leads with the caveat rather than burying it.

The instrument is worth having because of the funds, where the accrual is a real and regular
T-bill-shaped yield, and because it is the only way on this chain to separate a payout from the
share that earned it. It is not a way to buy a company's dividend yield, and the product says so.

## Market shape

A holder posts an offer (`offer`) naming the shares, the window and an asking price. Any buyer can
take it (`fund`). Unfunded offers are cancellable in full at any time. Settlement (`settle`) is
permissionless once mature.
