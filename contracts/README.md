# Contracts

Foundry. `solc 0.8.28`, `via_ir`, solady for math and auth.

`lib/` holds forge-std and solady **vendored rather than as git submodules**, trimmed to the source
each one needs to build (their own test suites, audit archives and docs are not carried). The repo
therefore builds and tests with no network access at all, which is what the fork tests need anyway
since they already spend their network budget on the chain. To work against upstream copies instead,
delete `lib/` and run `forge install foundry-rs/forge-std Vectorized/solady`.

```bash
forge build --root .
forge test --root .                                              # 90 tests, no network
RHC_RPC_URL=https://rpc-robinhood.blockmachine.io forge test --root . --match-path 'test/Fork.t.sol'
```

## Layout

| Path | What |
|---|---|
| `src/core/AssetRegistry.sol` | Per-ticker risk parameters and the shared notional cap. One registry across all four products, so an asset cannot be conservative enough to lend against and reckless enough to write options on. |
| `src/core/EquityOracle.sol` | Halt-aware price from a Uniswap v3 TWAP. Five distinct reasons to refuse. |
| `src/core/Corporate.sol` | Reads the chain's corporate-action channel and turns it into a strike adjustment. |
| `src/paid/OptionMath.sol` | Black-Scholes in wad. Hart's normal CDF, accurate to double-precision epsilon. |
| `src/paid/VolSurface.sol` | The only judgement call in the protocol, behind hard bounds and a staleness cliff. |
| `src/paid/PaidOrders.sol` | The venue. Fully collateralised covered calls and cash-secured puts. |
| `src/paid/UnderwriterVault.sol` | The bid that is always there. Not the market; the floor under it. |
| `src/credit/CreditLine.sol` | Cash without selling, with the halt priced into the LTV. |
| `src/savings/TermRepo.sol` | Fixed rate, funded by interest escrowed at matching. |
| `src/strip/AccrualStrip.sol` | Payout strips. Settles on multipliers, so no oracle is in the path. |

## Testing philosophy

**Reference values are generated independently.** Every expected price in `test/OptionMath.t.sol`
comes from `scripts/reference-prices.py`, evaluated in double precision against libm's `erf`, with
no shared code path. Testing a fixed-point implementation against values it produced itself proves
nothing.

**Harness contracts reproduce the real thing, they do not simplify it.** `TestStock` reverts rather
than returning false while paused, implements the two-level pause, keeps `oraclePaused` independent,
and publishes a scheduled multiplier ahead of time, because those are the behaviours the protocol is
built around. A halt cannot be scheduled on mainnet to suit a test, so the alternative to this file
is not testing against the real thing, it is not testing those paths at all.

**Fork tests fail rather than skip when configured.** `test/Fork.t.sol` skips when `RHC_RPC_URL` is
unset and fails when it is set but the fork cannot be created. A fork test that quietly becomes a
no-op reports green while checking nothing.

**Invariants are fuzzed.** `testFuzz_escrowIsNeverOverdrawn` and `testFuzz_escrowIsAlwaysConserved`
assert the one property that makes these products safe to describe in a sentence: whatever the
settlement price, the two sides together can never claim more than was escrowed.
