# Halts

An issuer of a Robinhood tokenized equity can pause it. While it is paused, `transfer`,
`transferFrom`, `approve` and `permit` all **revert**. Not return false: revert.

This is the single most important fact in this repository, because it breaks something in every
product that touches collateral, and it breaks it in a way that has no analogue on any other chain.

## The two flags, which are not the same thing

| Flag | Transfers | Price | What it means |
|---|---|---|---|
| `paused()` | revert | unusable | The token is frozen. It is the OR of a per-token flag and a registry-wide one, so a single switch can freeze all 254 at once. |
| `oraclePaused()` | work normally | unusable | The issuer is disavowing the price while leaving the token movable. |

`EquityOracle` returns a distinct `PriceStatus` for each (`TokenPaused`, `IssuerOraclePaused`) rather
than one generic failure, because the correct response differs: a frozen token cannot be settled
against at all, while a disavowed price can still be transferred, just not valued.

## Why "liquidation gets expensive" is the wrong model

The usual assumption behind a lending protocol is that a liquidation is always *possible*, and the
question is only what discount makes it attractive. Raise the incentive far enough and someone acts.

That is false here. During a halt the seizure is the transaction that reverts. A liquidator with
unlimited capital, offered a 100% discount, cannot do anything, for an interval nobody can bound in
advance because it is the issuer's decision and not a market outcome.

So the halt is an **option the issuer holds and the borrower sold**, and it has to be priced rather
than assumed away. Three mechanisms do that:

1. **A per-ticker halt buffer** on top of the ordinary loan-to-value ratio, in `AssetConfig`.
   $17,000 of collateral at 65% LTV with a 25% buffer supports $8,287, not $11,050.
2. **Flagging.** Any keeper may mark a position unsafe the instant before a freeze and is paid out of
   the penalty whenever the liquidation eventually happens. A halt stops being an escape from the
   penalty, and keepers are paid to *watch* rather than only to act.
3. **Debt ceilings sized to measured on-chain depth**, because what a liquidator could actually sell
   here is the only thing that makes a liquidation solvent.

## What each product does about it

| Product | What breaks | What happens instead |
|---|---|---|
| **Paid orders** | Settlement needs a price, and a call's payoff needs a share transfer. Both are unavailable. | `settle` is permissionless and reverts with the oracle's reason. It takes the first observation available at or after expiry, which during a freeze is the first one after it lifts. Both sides are told this before writing. |
| **Paid orders, claiming** | A settled call pays out in shares, which cannot move. | The claim reverts and can be retried. The settlement price is already fixed, so nothing about the outcome changes while waiting. |
| **Credit line** | Liquidation is impossible. | The halt buffer means the position had room to survive the freeze. Flagging records the claim during it and pays the keeper after. |
| **Term repo** | Foreclosure needs to move collateral. | Collateral requirements carry the same buffer. Foreclosure defers; the note's claim is unchanged when it resumes. |
| **Underwriter vault** | A harvest cannot sell the shares it just claimed. | Claim and sale are one transaction, so it never carries unhedged inventory between them. If the sale cannot happen, neither does the claim, and the shares stay in the venue's escrow. |
| **Payout strip** | Nothing. | Settlement reads no price and compares two multipliers. A halt delays the transfer and changes the outcome by zero wei. |

That last row is not a footnote. It is why the strip is the only product here whose behaviour under
a halt is genuinely uninteresting, and it falls directly out of settling on the multiplier rather
than on a price.

## The one property a halt does change

Settlement is permissionless and takes the price at the moment it is called. Under normal conditions
that is a race of a few blocks after expiry and worth nothing. During a long halt the window widens,
and whoever calls first after the freeze lifts chooses that instant.

Two things bound it and neither eliminates it:

- The price used is the oracle's **time-weighted average**, not a spot print, so the discretion is
  over a window average rather than over a tick.
- The oracle's deviation guard refuses to serve at all when the window average and the current tick
  disagree by more than the configured band, which is what a manipulated resume looks like.

This is a real, remaining property of the design and it is written down here rather than left for
someone to find. Bounding it further would require an off-chain attestation of when a halt ended,
which trades a small timing discretion for a new trusted party, and that is a worse deal.

## Testing it

Halts cannot be scheduled on mainnet to suit a test, so `test/harness/TestStock.sol` reproduces the
live implementation's behaviour exactly: reverting rather than returning false, the two-level pause,
and the independent oracle pause. `test/Fork.t.sol` then asserts that the surface it reproduces is
still the one the live chain has. Both halves are needed; either alone proves nothing.
