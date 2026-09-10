# Borrow against your stocks

> Get cash without selling.

Nobody needs that explained. A holder who sells a winner pays tax on it and gives up the position; a
holder who borrows against it does neither. All the complexity lives in a per-ticker haircut engine
the borrower never sees.

## What they see

One number: how much cash they can take. It is

```
capacity = collateralValue * maxLtvBps * (1 - haltBufferBps)
```

100 NVDA at $180 is $18,000. At 65% LTV with a 25% halt buffer that is **$8,775**, not the $11,700
an ordinary lender would offer. `test_capacityIsLtvMinusTheHaltBuffer` pins both numbers.

`borrowAgainst(asset, qtyRaw, cashWanted)` locks and draws in one call. `repayAndUnlock` reverses it.

## Where the second factor comes from

Not risk aversion. A specific, priceable event: the issuer can freeze the token, and while frozen no
transfer works, so a liquidator cannot seize the collateral at any price for an interval nobody can
bound in advance. [`halts.md`](halts.md) has the full argument. The buffer is the premium the
borrower pays for an option the issuer holds and they sold.

## Flagging

`flag(borrower, asset)` lets a keeper record that a position is unsafe **at the moment it becomes
unsafe**, which is the moment before a freeze rather than after it. The flagger is paid a share of
the liquidation penalty whenever the liquidation eventually happens.

This is what turns a halt from an escape hatch into a delay. Without it a borrower whose position
broke a second before a freeze faces no penalty at all if the freeze outlasts the drawdown, and
keepers have no reason to watch a market they cannot act in.
`test_liquidationIsImpossibleWhileHaltedAndTheFlagSurvivesIt` walks the whole sequence: breach,
flag, freeze, a liquidation attempt that reverts with `TokenPaused`, the freeze lifting, and the
flagger being paid.

## Interest

A two-slope kinked model on utilisation, folded into an index on every state change. Lenders supply
USDG with `supply` and hold shares in `cash + totalBorrows`.

**Closing a position means passing `type(uint256).max`, not a balance you just read.** `accrue` runs
inside the repayment and moves the number between the two calls, so repaying a pre-read figure
leaves dust and the subsequent unlock reverts as unhealthy. Every client in this repo passes the
maximum, and `test_repayAndUnlockReturnsTheShares` exists because the first version of it did not.

## Liquidation

Standard shape: repay up to `closeFactorBps` of the debt, seize collateral worth the repayment plus
`liquidationBonusBps`, priced off the same oracle reading that condemned the position. The flagger's
cut comes out of the bonus, not out of the borrower's remaining collateral.

Exposure is booked against the shared `AssetRegistry` cap in principal terms only. Interest repaid
above principal was never counted against the cap, so releasing it would let the cap drift upward
with every repayment; `_releaseNotional` releases at most what was booked.
