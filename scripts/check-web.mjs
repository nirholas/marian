#!/usr/bin/env node
/**
 * Load every page of the app in a real browser and assert it works.
 *
 * Not a screenshot tour. It fails on any console error, any uncaught exception, any failed network
 * request, and on any page that finishes loading still showing a loading skeleton, because a
 * skeleton that never resolves is the exact failure a screenshot would hide.
 *
 *   node scripts/check-web.mjs http://localhost:5411
 *   SHOT_DIR=/tmp/shots node scripts/check-web.mjs http://localhost:5411
 *
 * Screenshots are written outside the repo by default. They are regenerable output, they are large
 * next to everything else here, and a repo that accumulates them is a repo nobody can clone.
 */
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const base = process.argv[2] ?? 'http://localhost:5411';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const shots = process.env.SHOT_DIR ?? join(root, '.screenshots');
mkdirSync(shots, { recursive: true });

const PAGES = [
  ['overview', '#/', ['Name your price', 'tradable tickers']],
  ['paid', '#/paid', ['Name the price you would sell at', 'You get paid, today', 'Most this can be worth']],
  ['borrow', '#/borrow', ['Get cash without selling', 'Cash you can take', 'halt buffer']],
  ['savings', '#/savings', ['Lock dollars', 'You will be paid']],
  ['payouts', '#/payouts', ['Sell what your shares will pay you', 'Measured payout history']],
];

const browser = await chromium.launch();
const failures = [];

for (const [name, hash, expectations] of PAGES) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const problems = [];

  page.on('console', (message) => {
    if (message.type() === 'error' || message.type() === 'warning') {
      problems.push(`console.${message.type()}: ${message.text()}`);
    }
  });
  page.on('pageerror', (error) => problems.push(`uncaught: ${error.message}`));
  page.on('requestfailed', (request) => {
    // A wallet extension is not present in this browser and the app says so rather than requesting
    // anything, so any failed request here is a real one.
    problems.push(`request failed: ${request.url()} ${request.failure()?.errorText}`);
  });

  await page.goto(`${base}/${hash}`, { waitUntil: 'networkidle' });
  // Quotes are read from the chain after first paint. Give them a beat, then insist they landed.
  await page.waitForTimeout(2500);

  // `innerText` returns text as rendered, and several labels here are uppercased by CSS. Matching
  // case-sensitively against the source copy fails on styling rather than on substance.
  const text = (await page.locator('body').innerText()).toLowerCase();
  for (const expectation of expectations) {
    if (!text.includes(expectation.toLowerCase())) problems.push(`missing copy: "${expectation}"`);
  }

  const skeletons = await page.locator('.skeleton').count();
  if (skeletons > 0) problems.push(`${skeletons} loading skeleton(s) still on screen after settle`);

  // Responsive check at the narrow end, where a fixed width would break the layout.
  await page.setViewportSize({ width: 380, height: 900 });
  await page.waitForTimeout(300);
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1,
  );
  if (overflow) problems.push('horizontal overflow at 380px');
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.waitForTimeout(200);

  await page.screenshot({ path: join(shots, `${name}.png`), fullPage: true });

  if (problems.length) {
    failures.push({ name, problems });
    console.log(`FAIL ${name}`);
    for (const p of problems) console.log(`     ${p}`);
  } else {
    console.log(`ok   ${name}`);
  }
  await context.close();
}

await browser.close();

if (failures.length) {
  console.log(`\n${failures.length} page(s) failed`);
  process.exit(1);
}
console.log(`\nall ${PAGES.length} pages clean; screenshots in ${shots}`);
