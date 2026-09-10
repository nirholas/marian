# Deploying and operating

## Locally, against a fork of the real chain

```bash
pnpm install
node scripts/demo.mjs           # stays up
node scripts/demo.mjs --check   # same, asserts every surface, exits
```

This forks Robinhood Chain, deploys the whole system, configures the 12 deepest verified tickers,
posts a starting volatility surface, opens three savings terms, and seeds the vault and lending pool
with dollars conjured by writing USDG's balance slot. It then writes `packages/sdk/src/addresses.ts`
and `data/demo-deployment.json` from the deployment it just broadcast.

Two things it gets right that are easy to get wrong:

- **A forking anvil adopts the forked chain's id**, so the local node reports 4663 and not 31337.
  Filing the deployment under 31337 files it under an id nothing asks for, and the app then renders
  "not deployed" while talking to the node happily. The id is read, not assumed.
- **The well-known anvil accounts are EIP-7702 delegated on this chain**, so anything that inspects
  code at the sender behaves differently from a plain EOA. The demo generates a fresh key.

## To a real network

`contracts/script/Deploy.s.sol` takes its configuration from the environment:

| Variable | Meaning |
|---|---|
| `USDG_ADDRESS` | required |
| `SWAP_ROUTER_02` | required |
| `MARIAN_OWNER` | defaults to the broadcaster |
| `FEE_SINK` | defaults to the owner |
| `USDG_DECIMALS` | defaults to 6 |

```bash
forge script script/Deploy.s.sol:Deploy --root contracts \
  --rpc-url "$RHC_RPC_URL" --broadcast
```

### The order that matters

Only one edge is load-bearing: `UnderwriterVault` takes the `PaidOrders` address in its constructor,
and `PaidOrders` registers the vault as a buyer afterwards. The venue must exist before the vault
and the vault must be registered after both. Everything else is independent, and the script encodes
it.

### After deploying

Nothing can be written against a ticker the registry has never heard of, so a fresh deployment is
inert until configured. For each ticker:

1. `AssetRegistry.configure` - LTV, halt buffer, strike band, tenors, notional cap, fee
2. `EquityOracle.configure` - pool, token order, TWAP window, deviation band, adjustment blackout
3. `UniswapV3Venue.setFeeTier` - so a settled call can be sold back to dollars
4. `VolSurface.post` - from a reporter, or the venue will not quote

Configure only tickers whose pools you have verified with `node scripts/refresh-assets.mjs`. It
rejects a pool that is not that equity against USDG, and a token order that is claimed wrongly, which
is the one misconfiguration that produces a plausible wrong price rather than an error.

### Operating

- **A volatility reporter must keep posting.** `VolSurface` fails closed once a quote is older than
  `maxAge`: the venue stops quoting rather than quoting a number nobody stands behind. That is the
  intended behaviour, and it means a dead reporter is an outage.
- **A keeper must harvest settled vault positions.** `UnderwriterVault.harvest` claims and sells in
  one transaction so the vault never carries unhedged single-name equity between two.
- **A keeper should flag unsafe credit positions**, especially before a halt, or the penalty that
  pays for watching goes unclaimed.
- **Settlement is permissionless** and anyone may call it. Under normal conditions it is a race of a
  few blocks; during a halt the window widens. See the last section of [`halts.md`](halts.md), which
  states the residual discretion rather than hiding it.

## Testing

```bash
pnpm forge:test                                                  # 90 tests, no network
RHC_RPC_URL=https://rpc-robinhood.blockmachine.io pnpm fork:test  # 10 against the live chain
node scripts/check-web.mjs http://localhost:5273                  # every page in a real browser
```

The fork tests **skip** when `RHC_RPC_URL` is unset and **fail** when it is set but the fork cannot
be created. A fork test that quietly becomes a no-op reports green while checking nothing, and the
only tell is the gas figure.
