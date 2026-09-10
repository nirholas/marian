# @marian/sdk

Typed client for the Marian contracts on Robinhood Chain: ABIs, addresses, chain config, unit
conversions, and the arithmetic a UI needs before a user has committed to anything.

```bash
pnpm add @marian/sdk viem
```

## The units, which are the reason this package exists

Three of them, mixed constantly, and getting one wrong produces a number that is off by a factor of
a trillion while still looking like a number.

| Unit | Decimals | What it is |
|---|---|---|
| **raw** | 18 | A tokenized equity's own smallest unit. **Not a share.** |
| **usdg** | 6 | Dollars, as USDG holds them. |
| **price** | 8 | Dollars, as every oracle and strike in the protocol uses them. |

And one that is not a unit at all: `uiMultiplier`, the number of economic shares one raw unit
carries, at 1e18. A user thinks in shares, the chain stores raw units, and the multiplier is the
only thing relating them. It moves, on every corporate action.

```ts
import { parseShares, parsePrice, strikePerShareToRaw, usdgValue, formatUsdg } from '@marian/sdk';

const qtyRaw = parseShares('10');            // 10 shares -> 10n * 10n**18n
const strike = parsePrice('180.00');         // $180 a share -> 18000000000n
const strikeRaw = strikePerShareToRaw(strike, multiplier);
formatUsdg(usdgValue(qtyRaw, strikeRaw));    // "1800.00"
```

`parseShares` and `parsePrice` truncate rather than round, and never go through a float. A client
that rounds a strike up by a hundredth of a cent asks for a series the user did not name.

## Reading a quote

```ts
import { createPublicClient, http } from 'viem';
import { robinhoodChain, deploymentFor, paidordersAbi, upcomingExpiries, parseShares, parsePrice } from '@marian/sdk';

const client = createPublicClient({ chain: robinhoodChain, transport: http() });
const marian = deploymentFor(robinhoodChain.id);

const [premium, fee, maxProceeds, buyer] = await client.readContract({
  address: marian.paidOrders,
  abi: paidordersAbi,
  functionName: 'previewWrite',
  args: [nvda, BigInt(upcomingExpiries(4)[2]), true, parsePrice('200'), parseShares('10')],
});
```

`buyer` is the zero address when nobody is bidding, which is a real and common answer for a strike
far enough out that the option is worth less than a millionth of a dollar. Show it as a suggestion
to move the strike, not as an error.

**`maxProceeds` is not optional.** It is the ceiling on what a covered call can be worth however far
the stock runs, and displaying the premium without it is how a venue loses a writer on the first gap
up. `coveredCallOutcome` and `cashSecuredPutOutcome` return the cap and the forgone upside together
for exactly this reason.

## Expiries

```ts
import { upcomingExpiries, describeWait, isValidExpiry } from '@marian/sdk';

upcomingExpiries(6);        // the next six weekly grid dates, unix seconds
describeWait(expiry);       // "3 weeks" - the user chose a duration, not a date
isValidExpiry(someUnixTs);  // the venue only accepts dates on the grid
```

## ABIs

`abis.ts` is generated from the Foundry build by `scripts/emit-abis.mjs` and must not be hand-edited.
A hand-maintained ABI drifts from its contract silently: a changed return tuple produces a client
that decodes garbage rather than one that fails to compile.

```bash
pnpm forge:build && node scripts/emit-abis.mjs
```

`addresses.ts` is likewise written by `scripts/demo.mjs` from the deployment it broadcast, so every
address in it was created by a transaction rather than typed.
