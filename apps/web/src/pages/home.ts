import { escapeHtml } from '../components.js';
import { ACCRUAL, ASSETS, ASSETS_MEASURED_AT } from '../data.js';
import type { Connection } from '../chain.js';

/**
 * Four products, four sentences.
 *
 * The rule this page enforces on the whole product line: if a card needs a second sentence to make
 * sense, the product behind it is not ready to ship. Every noun below is one the reader already
 * owned before they arrived.
 */
const PRODUCTS = [
  {
    href: '#/paid',
    title: 'Paid orders',
    pitch:
      'Name the price you would happily sell at. Get paid to wait. If it gets there you sold at your price, and if it does not you just keep the cash.',
    foot: 'Covered calls and cash-secured puts',
  },
  {
    href: '#/borrow',
    title: 'Borrow against your stocks',
    pitch: 'Get cash without selling. Your shares stay yours, and so does everything they do next.',
    foot: 'Over-collateralised credit line',
  },
  {
    href: '#/savings',
    title: 'Fixed-term savings',
    pitch:
      'Lock dollars for a fixed term at a fixed rate. The whole term’s interest is escrowed the moment your deposit is matched.',
    foot: 'Term repo against equity collateral',
  },
  {
    href: '#/payouts',
    title: 'Sell your payouts',
    pitch:
      'Take the payouts your shares will earn over the next few months as cash today, and keep the shares.',
    foot: 'Payout strip, priced off measured accrual',
  },
];

export function renderHome(connection: Connection): string {
  const payers = ACCRUAL.filter((a) => a.paysDistributions).length;
  const measured = new Date(ASSETS_MEASURED_AT).toLocaleDateString(undefined, {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  });

  return `
    <p class="eyebrow">On ${escapeHtml(connection.label)}</p>
    <h1>Name your price. Get paid to wait.</h1>
    <p class="lede">
      Four things you can do with tokenized equities, each of which fits in one sentence and none of
      which asks you to learn a new word. Underneath: a fully collateralised options venue, a credit
      line that prices the risk of an issuer freezing your collateral, a term repo, and the only
      instrument on this chain that separates a payout from the share that earned it.
    </p>

    <div class="grid">
      ${PRODUCTS.map(
        (p) => `
        <a class="card" href="${p.href}">
          <h2>${escapeHtml(p.title)}</h2>
          <p class="pitch">${escapeHtml(p.pitch)}</p>
          <div class="card-foot"><span>${escapeHtml(p.foot)}</span><span aria-hidden="true">&rarr;</span></div>
        </a>`,
      ).join('')}
    </div>

    <section class="block">
      <div class="section-head">
        <h2>What this is built on</h2>
        <span class="faint">measured ${escapeHtml(measured)}</span>
      </div>
      <div class="grid">
        <div class="card">
          <h3>${ASSETS.length} tradable tickers</h3>
          <p class="pitch">
            Every one verified against the chain: the pool is really that equity against USDG, it
            stores enough observations for a thirty-minute average, and the token is not halted.
          </p>
        </div>
        <div class="card">
          <h3>${payers} of them pay out on chain</h3>
          <p class="pitch">
            A distribution here is a step in <code>uiMultiplier</code> and nothing else. Exactly the
            payers sit above 1.0; every other ticker sits at exactly 1.0, to the wei.
          </p>
        </div>
        <div class="card">
          <h3>Halts are the whole design</h3>
          <p class="pitch">
            While an issuer has a token paused, every transfer reverts, so collateral cannot be
            seized and settlement cannot complete. Each product below prices that explicitly rather
            than discovering it later.
          </p>
        </div>
      </div>
    </section>`;
}
