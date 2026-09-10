# Paid orders

> Name the price you would happily sell NVDA at. Get paid to wait. If it gets there, you sold at
> your price and you keep the cash. If it does not, you just keep the cash.

That sentence introduces no word the reader did not already own. Underneath it is a fully
collateralised European options venue.

## Fully collateralised, and therefore unliquidatable

A writer's obligation is escrowed in full at the moment they write: shares for a call, dollars for a
put. There is no margin engine, no maintenance ratio, no liquidator, and no path by which someone
who wrote one covered call loses more than the shares they already set aside.

Everything a margin engine would have bought is instead bought by refusing to let anyone write an
option they cannot cover.

## Settlement pays out of the escrow, in the escrow's own asset

This is the part that makes the sentence literally true.

**A call** settles by giving the long the fraction of the escrowed shares worth `S - K`:

```
longRaw = qtyRaw * (S - K) / S        writerRaw = qtyRaw - longRaw
```

The writer is left holding shares worth exactly `K * qty`. Their stock was called away at their
price. `test_callInTheMoney_writerKeepsExactlyTheStrikeValue` asserts precisely that.

**A put** settles by giving the long `K - S` of the escrowed dollars. The writer keeps dollars worth
exactly `S * qty`, which is the same position as having bought the stock at `K` and watched it fall
to `S`.

No settlement path needs a counterparty to arrive with cash, which is why no settlement path can
fail because one did not.

## Strikes are quoted per share and stored per raw unit

A raw unit is not a share. `uiMultiplier` relates them and it moves.

The user names "$180 a share". The protocol stores dollars per raw unit and re-derives the user's
number on the way out. When a corporate action moves the multiplier by ratio `r`, the raw strike is
multiplied by `r` and the promise is untouched:

```
strikeRaw' = strikeRaw * uiNew / uiOld
```

This is the adjustment the OCC applies by memo on a listed market, done here in code and in advance,
because `newUIMultiplier`/`effectiveAt` publish the next value before it lands. Scaling the strike
rather than the contract size is correct in both directions: a reverse split (`r < 1`) is the same
line as a dividend (`r > 1`), and the escrow can never be left short.

Without it, a dividend would raise the dollar value of a raw unit and drag the option into the money
with no move in the stock, and the writer would be assigned on a payout they were entitled to keep.

## Expiries are weekly, on a grid

Every series expires a whole number of weeks after Friday 2026-01-02 20:00 UTC. A venue with one bid
on each of a thousand user-chosen expiries has no bids; concentrating liquidity onto a handful of
dates is what makes any of them tradable.

Strikes are constrained too: a call must be at or above spot and a put at or below it, within a
per-ticker band. Allowing the other side would make the product a spot trade wearing an option's
clothes and would break the sentence it is sold on.

## Pricing

`OptionMath` is Black-Scholes in 1e18 fixed point, using Hart's rational approximation to the normal
CDF in the form published by West (2005). Measured against libm over `[-7, 7]` its worst absolute
error is 2.2e-16, which is double-precision epsilon.

That accuracy is not vanity. The obvious alternative, Abramowitz and Stegun 7.1.26, sits at 1.5e-7,
which is a tenth of a cent of pricing error on a $200 underlying: harmless economically, but large
enough that a reference test cannot tell it apart from a real sign error. Being exact is what makes
the test suite able to fail. Every expected value in `test/OptionMath.t.sol` is generated
independently by `scripts/reference-prices.py` in double precision, so nothing is a fixture recorded
from the implementation being tested.

The model exists for exactly one job: quoting the premium before a writer commits. Settlement never
uses it, because a settled option pays intrinsic out of collateral that is already there.

## Volatility, the only judgement call

Everything else here is arithmetic on facts the chain publishes. Volatility is a forecast, it is
what the premium is made of, and it is the one input a compromised reporter could use to make a user
write a call for nothing.

So `VolSurface` is bounded rather than trusted. A reporter can move ATM vol within `maxMoveBps` of
its previous value per update, cannot leave `[minVolWad, maxVolWad]`, and cannot quote at all once
its posting is `maxAge` old. A stale surface fails closed: the venue stops quoting rather than
quoting a number nobody has stood behind recently. The worst a captured reporter achieves is a
bounded drift over many blocks, in public, against a floor.

The surface is `vol(K) = atm + skew * ln(K/S)`, clamped. Two parameters, because a fitted surface
needs a fitter, and a fitter on chain is an unbounded loop in a quote path.

## Who takes the other side

The honest answer, and the one the design is built around.

`PaidOrders` polls every registered `IOptionBuyer` and routes the writer to the **best** bid. The
protocol's own `UnderwriterVault` is one of them, and it exists so that "no bids" is never the screen
a first-time writer sees. It is the floor under the market, not the market: a professional vol desk
that deploys its own `IOptionBuyer` immediately competes with it and the writer keeps the difference.

The vault buys what retail writes, which makes it **long volatility**, and the long side of an equity
option is historically the side that pays the variance risk premium rather than earning it. Bidding
at the surface's fair vol would therefore lose money slowly and invisibly, which is the worst
possible failure for a vault full of other people's capital.

So the vault does not bid fair value. It bids a vol below the surface (`volHaircutBps`) and then
takes a further cut of the premium (`edgeBps`), which is what a dealer buying retail flow has always
done. The writer still gets a real, instant, competitive price; the vault's expectancy under its own
model is positive; and the gap between the two is on chain rather than buried in a spread.

Its downside is bounded by construction: a long option cannot lose more than its premium, so the
worst case on any trade is known when it trades. `maxPremiumPerTradeUsdg`, `maxOpenPremiumUsdg` and
`minCashBps` cap how much of that worst case can be live at once.

## The part the interface must not soften

The simplification is honest right up until the stock rips past the strike, and at that moment the
writer meets a ceiling nobody drew for them.

`previewWrite` therefore returns `maxProceedsUsdg` alongside the premium, in the same unit, and the
UI renders the payoff against simply holding, with the forgone upside shaded and labelled. A writer
who signs after seeing that cannot be surprised by it later. Shipping the premium without the cap is
how a venue loses the cohort it spent to acquire, on the first violent gap up.
