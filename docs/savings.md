# Fixed-term savings

> Lock USDG for 30 days, earn 8%, guaranteed.

A certificate of deposit, which retail has understood for a century. Underneath it is a term repo
against tokenized equity collateral.

## Why the rate can honestly be called guaranteed

Most on-chain "fixed rate" products are a floating pool with a smoothing function on top, where the
fixed number is a forecast that breaks under stress.

This one is not. A borrower takes the deposit **for exactly its term**, posts over-collateralised
equity against it, and pays **the entire term's interest into escrow at the moment of matching**.
From that instant the lender's return is not a projection, it is a balance in the contract.
`test_matchingEscrowsTheEntireTermsInterestImmediately` asserts the dollars arrive.

- No duration mismatch: the loan's term *is* the deposit's term.
- No junior tranche absorbing a shortfall, because there is no shortfall to absorb.
- No rollover risk, because nothing rolls.

## The one thing a lender must understand

**Unmatched money earns nothing.** A deposit is either matched, earning its stated rate out of
dollars already escrowed, or idle and cancellable at any moment with no penalty and no notice. Those
are the only two states and the interface shows both rather than blending them into an average.
`test_unmatchedDepositEarnsNothingAndCancelsFreely` pins it.

## Collateral

`collateralRequired = principal * collateralRatioBps * (1 + haltBufferBps)`.

At the default 150% ratio with a 25% halt buffer, $100,000 borrowed needs $187,500 of equity. The
buffer widens the requirement here rather than narrowing a limit, because the constraint is on the
borrower posting rather than on a lender drawing, but it is the same halt and the same reasoning as
in [`credit.md`](credit.md).

A term repo does not margin-call mid-term. `collateralHealthBps` is exposed for a UI to display, and
nothing acts on it before maturity.

## Default

After maturity plus a grace period, anyone may `foreclose`: pay the principal in dollars, take the
collateral. That is what makes the lender whole, and it is why the lender's claim does not depend on
the borrower's cooperation.

During an issuer halt the collateral transfer reverts and foreclosure defers, with the claim
unchanged when it resumes. `test_haltDefersForeclosureWithoutLosingTheClaim` covers exactly that.
