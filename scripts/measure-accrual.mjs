#!/usr/bin/env node
/**
 * Reconstruct every ticker's payout history from the chain and write `data/accrual.json`.
 *
 * On Robinhood Chain a distribution is a step in `uiMultiplier` and nothing else, so the entire
 * payout record of a tokenized equity is recoverable by reading that one number at past blocks.
 * This walks the chain backwards, finds the blocks where the value changed, and reports the realised
 * accrual rate per ticker.
 *
 * The `AccrualStrip` UI quotes from this file rather than from an annualised guess, which matters
 * because for most single names the honest answer is "a few basis points a quarter" and only the
 * funds pay anything a saver would notice. Showing a projection instead of the measurement would be
 * the one dishonest screen in the product.
 *
 *   node scripts/measure-accrual.mjs [--samples 40]
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SEL, ethCallBatch, rpc, toBigInt } from './rpc.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const WAD = 10n ** 18n;
const SECONDS_PER_YEAR = 31_557_600;

const samplesArg = process.argv.indexOf('--samples');
const SAMPLES = samplesArg === -1 ? 120 : Number(process.argv[samplesArg + 1]);

const { assets } = JSON.parse(readFileSync(join(root, 'data', 'assets.json'), 'utf8'));

const head = Number(await rpc('eth_blockNumber', []));
const headBlock = await rpc('eth_getBlockByNumber', ['0x' + head.toString(16), false]);
const headTime = Number(headBlock.timestamp);
const genesisBlock = await rpc('eth_getBlockByNumber', ['0x1', false]);
const genesisTime = Number(genesisBlock.timestamp);
const secondsPerBlock = (headTime - genesisTime) / (head - 1);

console.log(`head block ${head}, chain age ${((headTime - genesisTime) / 86400).toFixed(1)} days, ` +
  `${secondsPerBlock.toFixed(3)}s per block`);

// Back the newest sample off the tip. These public endpoints do not agree on the head to the block,
// and an `eth_call` pinned to a block one of them has not imported yet returns a null result rather
// than an error. Tolerating that null is how a token whose payout landed yesterday gets recorded as
// having never paid at all: the series quietly falls back to an older sample.
const TIP_MARGIN = 5_000;
const newest = Math.max(1, head - TIP_MARGIN);
const blockAt = (i) => Math.max(1, Math.round(newest - (i * (newest - 1)) / SAMPLES));
const points = Array.from({ length: SAMPLES + 1 }, (_, i) => blockAt(i));

/** Read one token's multiplier at every sample point. */
async function series(address) {
  const out = [];
  for (let i = 0; i < points.length; i += 20) {
    const slice = points.slice(i, i + 20);
    const results = await ethCallBatch(
      slice.map((b) => ({ to: address, data: SEL.uiMultiplier, block: '0x' + b.toString(16) })),
      { archive: true },
    );
    slice.forEach((b, k) => out.push({ block: b, value: toBigInt(results[k]) }));
  }
  return out.reverse();
}

/** Collapse a sampled series into the distinct steps it passed through. */
function steps(rows) {
  const found = [];
  let previous = null;
  for (const row of rows) {
    if (row.value === null) continue;
    if (previous === null || row.value !== previous) {
      found.push(row);
      previous = row.value;
    }
  }
  return found;
}

/** The authoritative current value, read at `latest` rather than at a pinned block. */
async function liveMultiplier(address) {
  const [result] = await ethCallBatch([{ to: address, data: SEL.uiMultiplier }]);
  const value = toBigInt(result);
  if (value === null || value === 0n) throw new Error(`no live multiplier for ${address}`);
  return value;
}

const report = [];
for (const asset of assets) {
  const rows = await series(asset.address);
  // A null at an old block is a real answer: the token did not exist yet. A null near the tip is an
  // endpoint declining. Rather than trying to tell them apart, the series is anchored to a `latest`
  // read, which no endpoint refuses and which cannot be stale.
  const live = await liveMultiplier(asset.address);
  rows.push({ block: head, value: live });

  // A multiplier only ever steps up, except on a reverse split, and none has been observed on this
  // chain. A decrease is therefore either a genuine reverse split worth knowing about or bad data
  // worth knowing about, and both deserve to be recorded rather than averaged away.
  const observedRows = rows.filter((r) => r.value !== null);
  const decreases = observedRows.filter((r, i) => i > 0 && r.value < observedRows[i - 1].value).length;
  const passed = steps(rows);
  const first = passed.find((r) => r.value !== null);
  const last = rows.filter((r) => r.value !== null).at(-1);
  if (!first || !last) {
    report.push({ symbol: asset.symbol, address: asset.address, observed: false });
    continue;
  }

  const spanSeconds = Math.max(1, (last.block - first.block) * secondsPerBlock);
  const growth = Number(last.value - first.value) / Number(first.value);
  const annualisedBps = Math.round((growth * SECONDS_PER_YEAR * 10_000) / spanSeconds);

  // Two different numbers, and conflating them is the easy mistake. `growthBps` is what accrued
  // inside the sampled window; `cumulativeBps` is everything the token has ever paid, because a
  // multiplier starts life at exactly 1e18 and only ever steps on a payout. The second is the
  // honest headline, the first is what supports an annualised rate.
  const cumulative = Number(last.value - WAD) / Number(WAD);

  report.push({
    symbol: asset.symbol,
    address: asset.address,
    observed: true,
    startMultiplier: first.value.toString(),
    endMultiplier: last.value.toString(),
    /** Payout steps seen inside the sampled window, not counting the opening reading. */
    stepsObserved: Math.max(0, passed.length - 1),
    observedDays: Number((spanSeconds / 86400).toFixed(1)),
    growthBps: Math.round(growth * 10_000 * 100) / 100,
    cumulativeBps: Math.round(cumulative * 10_000 * 100) / 100,
    annualisedBps,
    decreasesObserved: decreases,
    paysDistributions: last.value > WAD,
  });
  process.stdout.write('.');
}
process.stdout.write('\n');

report.sort((a, b) => (b.annualisedBps ?? 0) - (a.annualisedBps ?? 0));
writeFileSync(
  join(root, 'data', 'accrual.json'),
  JSON.stringify(
    {
      chainId: 4663,
      measuredAt: new Date().toISOString(),
      headBlock: head,
      sampleCount: SAMPLES + 1,
      note:
        'Realised on-chain payout accrual per ticker, reconstructed from uiMultiplier at past ' +
        'blocks. Generated by scripts/measure-accrual.mjs.',
      tickers: report,
    },
    null,
    2,
  ),
);

console.log('symbol  steps  window    inWindow    cumulative   annualised');
for (const r of report.filter((x) => x.paysDistributions)) {
  console.log(
    `${r.symbol.padEnd(7)}${String(r.stepsObserved).padEnd(7)}${(r.observedDays + 'd').padEnd(10)}` +
      `${(r.growthBps + 'bps').padEnd(12)}${(r.cumulativeBps + 'bps').padEnd(13)}${(r.annualisedBps / 100).toFixed(2)}%`,
  );
}
console.log(`\nnon-payers: ${report.filter((x) => !x.paysDistributions).length} of ${report.length}`);
