import { escapeHtml, notice, figureRow, emptyState } from '../components.js';
import { percent } from '../format.js';
import { ACCRUAL, ACCRUAL_MEASURED_AT, ASSETS, type AccrualRow } from '../data.js';
import type { Connection } from '../chain.js';

/**
 * The payout page, and the one screen in this product that leads with a caveat.
 *
 * The measurement below is the honest one and it is not flattering: the accrual these tokens
 * actually pass through on chain is a fraction of the underlying company's real dividend. SGOV
 * annualises at well under the T-bill yield it tracks, and JNJ's on-chain accrual is a rounding
 * error next to its quarterly dividend. Quoting a real-world dividend yield here and letting a
 * buyer assume the chain pays it would be the one genuinely dishonest thing this product could do,
 * so the table shows what was measured, over the window it was measured in, and nothing else.
 */
export function mountPayouts(root: HTMLElement, connection: Connection) {
  root.innerHTML = view(connection);
}

function view(connection: Connection): string {
  const rows = ACCRUAL.filter((r) => r.observed).sort(
    (a, b) => (b.annualisedBps ?? 0) - (a.annualisedBps ?? 0),
  );
  const payers = rows.filter((r) => r.paysDistributions);
  const measured = new Date(ACCRUAL_MEASURED_AT).toLocaleDateString(undefined, {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  });

  if (rows.length === 0) {
    return emptyState(
      'Nothing measured yet',
      'Run <code>node scripts/measure-accrual.mjs</code> to reconstruct every ticker\'s payout history from the chain.',
    );
  }

  const best = payers[0];

  return `
    <p class="eyebrow">Payout strips</p>
    <h1>Sell what your shares will pay you.</h1>
    <p class="lede">
      Lock shares for a window you choose, take a lump sum today, and get the shares back at the end.
      Whatever they pay out during the window belongs to the buyer; the shares themselves never stop
      being yours.
    </p>

    ${figureRow([
      {
        label: 'Tickers that pay on chain',
        value: `${payers.length}`,
        qualifier: `of ${ASSETS.length} tradable, measured ${measured}`,
        tone: 'plain',
      },
      {
        label: 'Highest measured accrual',
        value: best ? percent(best.annualisedBps ?? 0, 2) : '--',
        qualifier: best ? `${best.symbol}, annualised from ${best.observedDays} days of history` : '',
        tone: 'good',
      },
      {
        label: 'Tickers that pay nothing',
        value: `${rows.length - payers.length}`,
        qualifier: 'multiplier sitting at exactly 1.0, to the wei',
        tone: 'plain',
      },
    ])}

    ${notice(
      `<div><strong>Read this before you buy a strip.</strong> What these tokens pass through on
       chain is materially less than the dividend the underlying company pays in the world. The
       column below is what was actually measured from the chain's own history, not a projection
       from a dividend calendar, and for most single names it is a few basis points. The instrument
       is worth having for the funds, and because it is the only way on this chain to separate a
       payout from the share that earned it. It is not a way to buy a company's dividend yield.</div>`,
      'warn',
    )}

    <section class="block">
      <div class="section-head">
        <h2>Measured payout history</h2>
        <span class="faint">reconstructed from <code>uiMultiplier</code> at past blocks</span>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Ticker</th>
              <th class="num">Payouts seen</th>
              <th class="num">Window</th>
              <th class="num">Total paid</th>
              <th class="num">Annualised</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            ${rows.map(row).join('')}
          </tbody>
        </table>
      </div>
    </section>

    <section class="block">
      <h2>How a strip settles</h2>
      <div class="grid">
        <div class="card">
          <h3>No price is ever read</h3>
          <p class="pitch">
            Settlement compares the token's multiplier at the start of the window with the one at the
            end, and splits the locked shares by that ratio. There is no oracle in the path, so there
            is nothing to manipulate and nothing to go stale.
          </p>
        </div>
        <div class="card">
          <h3>You end up with the shares you started with</h3>
          <p class="pitch">
            Not the same raw units, the same economic shares. The buyer's cut is exactly the
            accrual, computed so the escrow can never be overdrawn in either direction.
          </p>
        </div>
        <div class="card">
          <h3>A halt only delays it</h3>
          <p class="pitch">
            Because no price is involved, a freeze changes when the strip settles and not by a single
            wei what it settles for. It is the only product here with that property.
          </p>
        </div>
      </div>
    </section>`;
}

function row(r: AccrualRow): string {
  const pays = r.paysDistributions;
  return `
    <tr>
      <td><strong>${escapeHtml(r.symbol)}</strong></td>
      <td class="num">${r.stepsObserved ?? 0}</td>
      <td class="num">${r.observedDays ?? 0}d</td>
      <td class="num">${pays ? `${r.cumulativeBps}bps` : '0'}</td>
      <td class="num">${pays ? percent(r.annualisedBps ?? 0, 2) : '0.00%'}</td>
      <td>${pays ? '<span class="tag pays">pays out</span>' : '<span class="tag">no payouts</span>'}</td>
    </tr>`;
}
