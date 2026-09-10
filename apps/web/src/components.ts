import { usd, price, withCommas } from './format.js';

export const el = (html: string): HTMLElement => {
  const wrapper = document.createElement('div');
  wrapper.innerHTML = html.trim();
  return wrapper.firstElementChild as HTMLElement;
};

export const escapeHtml = (input: string): string =>
  input.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/**
 * A headline number and the thing that qualifies it.
 *
 * `qualifier` is required by the type, not by convention. The premium without the cap, the credit
 * capacity without the halt buffer, and the rate without "only once matched" are each a true number
 * that leaves a false impression, and this component exists so that shipping one is a compile
 * error rather than an oversight.
 */
export function figure(options: {
  label: string;
  value: string;
  qualifier: string;
  tone?: 'good' | 'capped' | 'plain';
}): string {
  const tone = options.tone && options.tone !== 'plain' ? ` ${options.tone}` : '';
  return `
    <div class="figure${tone}">
      <span class="label">${escapeHtml(options.label)}</span>
      <span class="value">${escapeHtml(options.value)}</span>
      <span class="qualifier">${escapeHtml(options.qualifier)}</span>
    </div>`;
}

export function notice(body: string, tone: 'plain' | 'warn' | 'danger' = 'plain'): string {
  const cls = tone === 'plain' ? 'notice' : `notice ${tone}`;
  return `<div class="${cls}">${body}</div>`;
}

export function emptyState(title: string, body: string, action = ''): string {
  return `
    <div class="empty">
      <h3>${escapeHtml(title)}</h3>
      <p class="muted">${body}</p>
      ${action}
    </div>`;
}

export function skeletonRows(count: number, width = '100%'): string {
  return Array.from({ length: count }, () => `<div class="skeleton" style="width:${width};height:18px"></div>`)
    .join('');
}

/**
 * The payoff of a covered call or a cash-secured put, drawn against simply holding the shares.
 *
 * This chart is the single most important thing on the writing screen and it exists for one reason.
 * The pitch ("get paid to wait") is honest right up until the stock rips through the strike, and at
 * that moment the writer discovers a ceiling nobody drew for them. So the ceiling is drawn first:
 * the flat segment above the strike is the widest part of the plot, the "just holding" line runs
 * away above it, and the gap between them is filled and labelled. A user who signs after seeing
 * this cannot be surprised by it later.
 */
export function payoffChart(options: {
  kind: 'call' | 'put';
  spot1e8: bigint;
  strike1e8: bigint;
  premiumUsdg: bigint;
  qtyRaw: bigint;
  rawOne: bigint;
  usdgOne: bigint;
  priceOne: bigint;
}): string {
  const { kind, spot1e8, strike1e8, premiumUsdg, qtyRaw, rawOne, usdgOne, priceOne } = options;
  const spot = Number(spot1e8) / Number(priceOne);
  const strike = Number(strike1e8) / Number(priceOne);
  const qty = Number(qtyRaw) / Number(rawOne);
  const premium = Number(premiumUsdg) / Number(usdgOne);

  const lo = Math.max(0, Math.min(spot, strike) * 0.55);
  const hi = Math.max(spot, strike) * 1.5;
  const steps = 96;

  const hold = (s: number) => qty * s;
  const written = (s: number) =>
    kind === 'call' ? qty * Math.min(s, strike) + premium : qty * s + premium - qty * Math.max(0, strike - s);

  const samples = Array.from({ length: steps + 1 }, (_, i) => lo + ((hi - lo) * i) / steps);
  const values = samples.flatMap((s) => [hold(s), written(s)]);
  const yLo = Math.min(...values) * 0.96;
  const yHi = Math.max(...values) * 1.04;

  const W = 640;
  const H = 260;
  const PAD = { top: 14, right: 16, bottom: 30, left: 58 };

  const x = (s: number) => PAD.left + ((s - lo) / (hi - lo)) * (W - PAD.left - PAD.right);
  const y = (v: number) => PAD.top + (1 - (v - yLo) / (yHi - yLo)) * (H - PAD.top - PAD.bottom);

  const path = (fn: (s: number) => number) =>
    samples.map((s, i) => `${i === 0 ? 'M' : 'L'}${x(s).toFixed(1)},${y(fn(s)).toFixed(1)}`).join(' ');

  const gapArea =
    kind === 'call'
      ? `M${x(strike).toFixed(1)},${y(written(strike)).toFixed(1)} ` +
        samples.filter((s) => s >= strike).map((s) => `L${x(s).toFixed(1)},${y(hold(s)).toFixed(1)}`).join(' ') +
        ` L${x(hi).toFixed(1)},${y(written(hi)).toFixed(1)} Z`
      : '';

  const ticks = [lo, (lo + hi) / 2, hi].map(
    (s) =>
      `<text x="${x(s).toFixed(1)}" y="${H - 10}" fill="#626b7a" font-size="11" text-anchor="middle">$${withCommas(s.toFixed(0))}</text>`,
  ).join('');

  const yTicks = [yLo, (yLo + yHi) / 2, yHi].map(
    (v) =>
      `<text x="${PAD.left - 8}" y="${(y(v) + 4).toFixed(1)}" fill="#626b7a" font-size="11" text-anchor="end">$${withCommas(Math.round(v).toString())}</text>` +
      `<line x1="${PAD.left}" y1="${y(v).toFixed(1)}" x2="${W - PAD.right}" y2="${y(v).toFixed(1)}" stroke="#1e222b" stroke-width="1"/>`,
  ).join('');

  const capLabel =
    kind === 'call'
      ? `<text x="${Math.min(W - PAD.right - 6, x(strike) + 10).toFixed(1)}" y="${(y(written(hi)) - 10).toFixed(1)}" fill="#fbbf24" font-size="12">upside you gave up</text>`
      : '';

  return `
    <div class="payoff">
      <svg viewBox="0 0 ${W} ${H}" role="img"
           aria-label="Payoff of this position at expiry compared with simply holding the shares.">
        ${yTicks}
        ${gapArea ? `<path d="${gapArea}" fill="#fbbf24" fill-opacity="0.13"/>` : ''}
        <line x1="${x(strike).toFixed(1)}" y1="${PAD.top}" x2="${x(strike).toFixed(1)}" y2="${H - PAD.bottom}"
              stroke="#4ade80" stroke-width="1" stroke-dasharray="4 4"/>
        <line x1="${x(spot).toFixed(1)}" y1="${PAD.top}" x2="${x(spot).toFixed(1)}" y2="${H - PAD.bottom}"
              stroke="#2b313d" stroke-width="1"/>
        <path d="${path(hold)}" fill="none" stroke="#626b7a" stroke-width="1.75" stroke-dasharray="5 4"/>
        <path d="${path(written)}" fill="none" stroke="#4ade80" stroke-width="2.5" stroke-linejoin="round"/>
        ${capLabel}
        ${ticks}
        <text x="${x(strike).toFixed(1)}" y="${PAD.top + 11}" fill="#4ade80" font-size="11" text-anchor="middle">your price</text>
      </svg>
      <div class="legend">
        <span><i class="swatch" style="background:#4ade80"></i>this position</span>
        <span><i class="swatch" style="background:#626b7a"></i>just holding</span>
        ${kind === 'call' ? '<span><i class="swatch" style="background:#fbbf24"></i>upside above your price goes to the buyer</span>' : ''}
      </div>
    </div>`;
}

/** A labelled row of figures, used at the top of every product screen. */
export function figureRow(items: Array<Parameters<typeof figure>[0]>): string {
  return `<div class="figure-row">${items.map(figure).join('')}</div>`;
}

export { usd, price };
