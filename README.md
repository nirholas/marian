# Marian

**Name your price. Get paid to wait.**

Four things you can do with tokenized equities on [Robinhood Chain](https://robinhoodchain.blockscout.com),
each of which fits in one sentence and none of which asks you to learn a new word.

| | The sentence | What it actually is |
|---|---|---|
| **Paid orders** | Name the price you would happily sell at. Get paid to wait. If it gets there you sold at your price, and if it does not you just keep the cash. | A fully collateralised European covered-call and cash-secured-put venue with an on-chain Black-Scholes quote, a bounded volatility surface, and an always-on underwriter of last resort |
| **Borrow** | Get cash without selling. | An over-collateralised credit line whose loan-to-value carries an explicit, per-ticker premium for the risk that the issuer freezes your collateral |
| **Savings** | Lock dollars for a fixed term at a fixed rate. | A term repo in which the borrower escrows the entire term's interest at the moment of matching, so the rate is a balance rather than a forecast |
| **Payouts** | Take the payouts your shares will earn as cash today, and keep the shares. | A payout strip built on the only observable form a distribution takes on this chain, settling with no oracle in the path at all |

Everything shares one asset registry, one price source and one view of what a halt means, so a
ticker that is too thin to write an option on is also too thin to lend against.

---

## Why this chain, and why these four

Robinhood Chain carries 254 tokenized equities. Every one is a beacon proxy onto a single `Stock`
implementation, which means one interface describes all of them, and that implementation does three
things no ordinary ERC-20 does. Each of the four products above exists because of one of them.

**1. The issuer can freeze a token, and while frozen every transfer reverts.**
Not "liquidation becomes expensive". Liquidation becomes *impossible*, at any price, for an interval
nobody can bound in advance: the seizure is the transaction that reverts. A liquidator with infinite
capital and a 100% discount cannot act. No mainnet collateral has ever had this property, and
lending against it as though it were ordinary collateral is how a protocol finds out it wrote an
option it never priced. [`docs/halts.md`](docs/halts.md) is the full table of what works and what
does not during a halt, and every row of it is a test.

**2. A corporate action arrives as a change to one number, published in advance.**
`uiMultiplier` is how many economic shares one raw unit carries. A split, a reverse split and a
dividend all move it and move nothing else, and `newUIMultiplier`/`effectiveAt` publish the next
value *before* it lands. So an option series here can adjust its own strike ahead of a corporate
action rather than by memo afterwards, which is what stops a dividend dragging a covered call into
the money on a payout the writer was entitled to keep. See [`Corporate`](contracts/src/core/Corporate.sol).

**3. That same number is the only place a payout is observable.**
On 2026-09-10 all 38 liquid tickers were read directly. Exactly eight sat above `1e18` and they were
exactly the eight that pay a distribution; every other one sat at exactly `1e18`, to the wei.
Sampled backwards through the chain's history, each is a step function that moves once per payout.
That makes a payout strippable in the most literal way available anywhere in DeFi, and
[`AccrualStrip`](contracts/src/strip/AccrualStrip.sol) is what falls out.

**And there is no price oracle on this chain at all.** No Chainlink, no Pyth, no first-party feed.
There is a Uniswap v3 deployment with real depth in USDG pairs and an issuer publishing halt flags.
[`EquityOracle`](contracts/src/core/EquityOracle.sol) is what those two facts add up to, including
the four distinct reasons it refuses to answer.

---

## Run it

The whole system, deployed against a fork of the real chain, in one command:

```bash
pnpm install
node scripts/demo.mjs            # fork, deploy, configure 12 verified tickers, seed, stay up
pnpm dev                         # the app, on http://localhost:5273
```

`scripts/demo.mjs --check` does the same and then asserts every surface answers before exiting, so
it works as a smoke test in a pipeline.

The fork is the point: every equity, pool, multiplier and halt flag is the real one, read from the
real chain, so the deployment is configured against the same facts a mainnet deployment would be.
Only block production and the dollars are local.

```bash
pnpm forge:test                  # 90 tests, no network needed
RHC_RPC_URL=https://rpc-robinhood.blockmachine.io pnpm fork:test   # 10 more, against the live chain
node scripts/check-web.mjs http://localhost:5273                   # every page, in a real browser
```

## Repository

```
contracts/          Foundry. 100 tests, 10 of them against the live chain.
  src/core/         AssetRegistry, EquityOracle, Corporate
  src/paid/         PaidOrders, OptionMath, VolSurface, UnderwriterVault, UniswapV3Venue
  src/credit/       CreditLine
  src/savings/      TermRepo
  src/strip/        AccrualStrip
packages/sdk/       Typed client. ABIs are generated from the build, never hand-written.
apps/web/           The four product surfaces.
scripts/            Chain measurement, deployment, and the browser check.
data/               What was measured off the chain, checked in, with the date it was measured.
docs/               How each piece works and why.
```

## Documentation

- [`docs/halts.md`](docs/halts.md) - what a halt breaks in each product, and how each one answers
- [`docs/paid-orders.md`](docs/paid-orders.md) - the venue: collateral, settlement, pricing, and who takes the other side
- [`docs/credit.md`](docs/credit.md) - the credit line and where the halt buffer comes from
- [`docs/savings.md`](docs/savings.md) - why the fixed rate is honest
- [`docs/payouts.md`](docs/payouts.md) - the strip, and the measurement it rests on
- [`docs/oracle.md`](docs/oracle.md) - pricing an equity on a chain with no oracle
- [`docs/measurements.md`](docs/measurements.md) - every chain fact this repo asserts, and how to re-derive it
- [`docs/deploy.md`](docs/deploy.md) - deploying, configuring and operating it

## What is deliberately not here

**No margin engine.** Every obligation is collateralised in full at the moment it is taken, so there
is no maintenance ratio and no liquidator in the options venue. That is not a shortcut. It is the
property that lets the product be described in one sentence honestly.

**No tranches, no autocallables, no delta-neutral basis vaults.** Each one requires a user to trust
a mechanism they cannot picture, and the last is where retail has historically been hurt worst.

**No dividend-yield projections.** The payouts page shows the accrual measured from the chain's own
history and says plainly that it is materially below the underlying company's real dividend. That
number is unflattering and it is the number.

## Licence

MIT.
