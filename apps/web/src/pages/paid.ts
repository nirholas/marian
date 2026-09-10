import type { Address } from 'viem';
import { upcomingExpiries, describeWait, parseShares, parsePrice, PRICE_ONE, RAW_ONE, USDG_ONE, WAD } from '@marian/sdk';
import { el, escapeHtml, figureRow, notice, payoffChart, emptyState } from '../components.js';
import { usd, price as fmtPrice, shares as fmtShares, calendarDate, relativeTime } from '../format.js';
import { ASSETS, assetBySymbol, readLiveAsset, paidordersAbi, STOCK_ABI, type Asset, type LiveAsset } from '../data.js';
import { connectWallet, currentWallet, type Connection } from '../chain.js';

type Side = 'call' | 'put';

type State = {
  side: Side;
  symbol: string;
  sharesInput: string;
  strikeInput: string;
  expiry: number;
  live: LiveAsset | null;
  quote: { premium: bigint; fee: bigint; maxProceeds: bigint; buyer: Address } | null;
  status: string;
  error: string;
  busy: boolean;
};

const OFFSETS = [5, 10, 15, 25];

export function mountPaid(root: HTMLElement, connection: Connection) {
  const first = ASSETS[0];
  if (!first) {
    root.innerHTML = emptyState('No tradable tickers', 'Run <code>node scripts/refresh-assets.mjs</code> to verify the asset list against the chain.');
    return;
  }

  const state: State = {
    side: 'call',
    symbol: first.symbol,
    sharesInput: '10',
    strikeInput: '',
    expiry: upcomingExpiries(6)[2],
    live: null,
    quote: null,
    status: '',
    error: '',
    busy: false,
  };

  let quoteToken = 0;

  const asset = (): Asset => assetBySymbol(state.symbol) ?? first;

  async function refreshLive() {
    state.live = null;
    render();
    try {
      state.live = await readLiveAsset(connection, asset());
      if (!state.strikeInput && state.live.spot1e8 > 0n) applyOffset(OFFSETS[1]);
    } catch (error) {
      state.error = `Could not read ${state.symbol} from the chain: ${(error as Error).message}`;
    }
    render();
    void refreshQuote();
  }

  function applyOffset(percentOffset: number) {
    const spot = state.live?.spot1e8 ?? 0n;
    if (spot === 0n) return;
    const direction = state.side === 'call' ? 100 + percentOffset : 100 - percentOffset;
    const target = (spot * BigInt(direction)) / 100n;
    // Whole dollars. A strike of $217.4193 is not a price anyone names, and rounding to something
    // sayable is also what makes two writers land on the same series.
    const rounded = (target / PRICE_ONE) * PRICE_ONE;
    state.strikeInput = (Number(rounded) / Number(PRICE_ONE)).toFixed(2);
  }

  async function refreshQuote() {
    const token = ++quoteToken;
    state.quote = null;
    state.error = '';
    if (!connection.deployment || !state.live || state.live.spot1e8 === 0n) return render();

    let qtyRaw: bigint;
    let strike1e8: bigint;
    try {
      qtyRaw = parseShares(state.sharesInput || '0');
      strike1e8 = parsePrice(state.strikeInput || '0');
    } catch {
      state.error = 'Those numbers are not quite right.';
      return render();
    }
    if (qtyRaw <= 0n || strike1e8 <= 0n) return render();

    // The venue only writes sell orders above the market and buy orders below it, so say so here
    // rather than letting the transaction be the thing that explains it.
    const spotPerShare = (state.live.spot1e8 * WAD) / state.live.multiplier;
    if (state.side === 'call' && strike1e8 < spotPerShare) {
      state.error = `A price to sell at has to be at or above the current ${fmtPrice(spotPerShare)}.`;
      return render();
    }
    if (state.side === 'put' && strike1e8 > spotPerShare) {
      state.error = `A price to buy at has to be at or below the current ${fmtPrice(spotPerShare)}.`;
      return render();
    }

    render();
    try {
      const result = (await connection.client.readContract({
        address: connection.deployment.paidOrders,
        abi: paidordersAbi,
        functionName: 'previewWrite',
        args: [asset().address, BigInt(state.expiry), state.side === 'call', strike1e8, qtyRaw],
      })) as [bigint, bigint, bigint, Address];

      if (token !== quoteToken) return;
      const [premium, fee, maxProceeds, buyer] = result;
      state.quote = { premium, fee, maxProceeds, buyer };
      if (buyer === '0x0000000000000000000000000000000000000000') {
        state.error =
          'Nobody is bidding at that price for that long. A price closer to today’s, or a longer wait, will find one.';
      }
    } catch (error) {
      if (token !== quoteToken) return;
      state.error = readableError(error);
    }
    render();
  }

  async function submit() {
    if (!connection.deployment || !state.quote) return;
    state.busy = true;
    state.error = '';
    state.status = 'Waiting for your wallet';
    render();

    try {
      const wallet = currentWallet() ?? (await connectWallet(connection));
      const qtyRaw = parseShares(state.sharesInput);
      const strike1e8 = parsePrice(state.strikeInput);
      const target = state.side === 'call' ? asset().address : undefined;

      if (state.side === 'call') {
        state.status = 'Approving the shares';
        render();
        await wallet.client.writeContract({
          account: wallet.address,
          chain: null,
          address: asset().address,
          abi: STOCK_ABI_WRITE,
          functionName: 'approve',
          args: [connection.deployment.paidOrders, qtyRaw],
        });
      }

      state.status = 'Writing the order';
      render();
      // A floor of 99% of the quote. Between the quote and the block the surface can move, and a
      // writer who was shown a number should not be filled meaningfully below it in silence.
      const floor = (state.quote.premium * 99n) / 100n;
      const hash = await wallet.client.writeContract({
        account: wallet.address,
        chain: null,
        address: connection.deployment.paidOrders,
        abi: paidordersAbi,
        functionName: state.side === 'call' ? 'writeCall' : 'writePut',
        args: [asset().address, qtyRaw, strike1e8, BigInt(state.expiry), floor],
      });

      state.status = `Done. ${hash.slice(0, 10)}...`;
      void target;
    } catch (error) {
      state.error = readableError(error);
      state.status = '';
    }
    state.busy = false;
    render();
    void refreshQuote();
  }

  function render() {
    root.innerHTML = view(connection, state);
    wire();
  }

  function wire() {
    root.querySelectorAll<HTMLElement>('[data-side]').forEach((node) =>
      node.addEventListener('click', () => {
        state.side = node.dataset.side as Side;
        state.strikeInput = '';
        applyOffset(OFFSETS[1]);
        void refreshQuote();
      }),
    );

    root.querySelector<HTMLSelectElement>('#ticker')?.addEventListener('change', (event) => {
      state.symbol = (event.target as HTMLSelectElement).value;
      state.strikeInput = '';
      void refreshLive();
    });

    root.querySelector<HTMLInputElement>('#shares')?.addEventListener('input', (event) => {
      state.sharesInput = (event.target as HTMLInputElement).value;
      void refreshQuote();
    });

    root.querySelector<HTMLInputElement>('#strike')?.addEventListener('input', (event) => {
      state.strikeInput = (event.target as HTMLInputElement).value;
      void refreshQuote();
    });

    root.querySelectorAll<HTMLElement>('[data-offset]').forEach((node) =>
      node.addEventListener('click', () => {
        applyOffset(Number(node.dataset.offset));
        void refreshQuote();
      }),
    );

    root.querySelectorAll<HTMLElement>('[data-expiry]').forEach((node) =>
      node.addEventListener('click', () => {
        state.expiry = Number(node.dataset.expiry);
        void refreshQuote();
      }),
    );

    root.querySelector<HTMLButtonElement>('#submit')?.addEventListener('click', () => void submit());
  }

  void refreshLive();
}

const STOCK_ABI_WRITE = [
  { type: 'function', name: 'approve', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }], stateMutability: 'nonpayable' },
] as const;

function view(connection: Connection, state: State): string {
  const asset = assetBySymbol(state.symbol)!;
  const live = state.live;
  const spotPerShare = live && live.multiplier > 0n ? (live.spot1e8 * WAD) / live.multiplier : 0n;

  const qtyRaw = safeShares(state.sharesInput);
  const strike1e8 = safePrice(state.strikeInput);

  const sellSide = state.side === 'call';
  const heading = sellSide ? 'Name the price you would sell at' : 'Name the price you would buy at';

  const chart =
    live && spotPerShare > 0n && strike1e8 > 0n && qtyRaw > 0n
      ? payoffChart({
          kind: state.side,
          spot1e8: spotPerShare,
          strike1e8,
          premiumUsdg: state.quote?.premium ?? 0n,
          qtyRaw,
          rawOne: RAW_ONE,
          usdgOne: USDG_ONE,
          priceOne: PRICE_ONE,
        })
      : '<div class="payoff"><div class="skeleton" style="height:220px"></div></div>';

  return `
    <p class="eyebrow">Paid orders</p>
    <h1>${escapeHtml(heading)}</h1>
    <p class="lede">
      ${sellSide
        ? 'You get paid the moment you set it. If the stock reaches your price you sold at your price and you keep the cash. If it does not, you keep the cash and the shares.'
        : 'You get paid the moment you set it. If the stock falls to your price you own it there, at a cost reduced by the cash. If it does not, you keep the cash.'}
    </p>

    <div class="chips" style="margin-bottom:24px">
      <button class="chip" data-side="call" aria-pressed="${sellSide}">I would sell</button>
      <button class="chip" data-side="put" aria-pressed="${!sellSide}">I would buy</button>
    </div>

    ${connection.deployment ? '' : notice(
      '<div><strong>No deployment on this network.</strong> The numbers below need a live venue. ' +
      'Run <code>node scripts/demo.mjs</code> to bring one up against a fork of the real chain.</div>',
      'warn',
    )}

    <div class="split">
      <form class="form card" onsubmit="return false">
        <div class="field">
          <label for="ticker">Ticker</label>
          <div class="control">
            <select id="ticker">
              ${ASSETS.map(
                (a) => `<option value="${a.symbol}"${a.symbol === state.symbol ? ' selected' : ''}>${escapeHtml(a.symbol)}</option>`,
              ).join('')}
            </select>
          </div>
          <span class="hint">
            ${live
              ? spotPerShare > 0n
                ? `Trading at ${fmtPrice(spotPerShare)} a share`
                : 'The venue will not price this right now'
              : 'Reading the chain...'}
          </span>
        </div>

        <div class="field">
          <label for="shares">Shares</label>
          <div class="control">
            <input id="shares" inputmode="decimal" value="${escapeHtml(state.sharesInput)}" aria-describedby="shares-hint" />
            <span class="prefix">${escapeHtml(asset.symbol)}</span>
          </div>
          <span class="hint" id="shares-hint">
            ${sellSide ? 'These are set aside until the date you choose.' : 'The cash for these is set aside until the date you choose.'}
          </span>
        </div>

        <div class="field">
          <label for="strike">Your price</label>
          <div class="control">
            <span class="prefix">$</span>
            <input id="strike" inputmode="decimal" value="${escapeHtml(state.strikeInput)}" />
          </div>
          <div class="chips">
            ${OFFSETS.map((o) => `<button type="button" class="chip" data-offset="${o}">${sellSide ? '+' : '-'}${o}%</button>`).join('')}
          </div>
        </div>

        <div class="field">
          <label>How long you will wait</label>
          <div class="chips">
            ${upcomingExpiries(6)
              .map(
                (e) =>
                  `<button type="button" class="chip" data-expiry="${e}" aria-pressed="${e === state.expiry}" title="${escapeHtml(calendarDate(e))}">${escapeHtml(describeWait(e))}</button>`,
              )
              .join('')}
          </div>
          <span class="hint">Settles ${escapeHtml(calendarDate(state.expiry))}, ${escapeHtml(relativeTime(state.expiry))}.</span>
        </div>

        <button class="btn" id="submit" ${state.busy || !state.quote || state.quote.buyer === '0x0000000000000000000000000000000000000000' ? 'disabled' : ''}>
          ${state.busy ? escapeHtml(state.status || 'Working...') : sellSide ? 'Get paid to wait' : 'Get paid to wait'}
        </button>
        ${state.status && !state.busy ? notice(`<div>${escapeHtml(state.status)}</div>`) : ''}
        ${state.error ? notice(`<div>${escapeHtml(state.error)}</div>`, 'warn') : ''}
      </form>

      <div class="stack">
        ${quoteBlock(state, qtyRaw, strike1e8, spotPerShare)}
        ${chart}
        ${halts(asset, live)}
      </div>
    </div>`;
}

function quoteBlock(state: State, qtyRaw: bigint, strike1e8: bigint, spotPerShare: bigint): string {
  if (!state.quote) {
    return `<div class="figure-row">
      <div class="figure"><span class="label">You get paid</span><div class="skeleton" style="width:120px;height:34px"></div><span class="qualifier">reading the venue</span></div>
      <div class="figure"><span class="label">Most this can be worth</span><div class="skeleton" style="width:120px;height:34px"></div><span class="qualifier">&nbsp;</span></div>
    </div>`;
  }

  const { premium, maxProceeds, fee } = state.quote;
  const sellSide = state.side === 'call';
  const capNote = sellSide
    ? `${fmtShares(qtyRaw, 0)} shares sold at ${fmtPrice(strike1e8)}, plus the cash. Nothing above it.`
    : `The cash you set aside, plus the cash you were paid. Nothing above it.`;

  return figureRow([
    {
      label: 'You get paid, today',
      value: usd(premium),
      qualifier: fee > 0n ? `after a ${usd(fee)} protocol fee` : 'no fee on this trade',
      tone: 'good',
    },
    {
      label: 'Most this can be worth',
      value: usd(maxProceeds),
      qualifier: capNote,
      tone: 'capped',
    },
    {
      label: sellSide ? 'If it never gets there' : 'If it never falls there',
      value: usd(premium),
      qualifier: sellSide ? 'you keep the shares and the cash' : 'you keep the cash and buy nothing',
      tone: 'plain',
    },
  ]) + (spotPerShare > 0n ? '' : '');
}

function halts(asset: Asset, live: LiveAsset | null): string {
  if (!live) return '';
  if (live.paused) {
    return notice(
      `<div><strong>${escapeHtml(asset.symbol)} is halted by its issuer.</strong> While it is, no transfer of it can happen at all, so nothing can be written or settled. Existing positions settle at the first price available after the halt lifts.</div>`,
      'danger',
    );
  }
  if (live.oraclePaused) {
    return notice(
      `<div><strong>${escapeHtml(asset.symbol)}'s issuer has disavowed its price.</strong> Transfers still work, but this venue will not quote against a price the issuer will not stand behind.</div>`,
      'warn',
    );
  }
  const drifted = live.multiplier > 10n ** 18n;
  return notice(
    `<div><strong>What happens if the company pays out.</strong> On this chain a dividend moves the token's multiplier${drifted ? `, and ${escapeHtml(asset.symbol)}'s has already moved` : ''}. Your price is adjusted by the same ratio the moment it does, so a payout can never drag your shares away from you. The payout stays yours.</div>`,
  );
}

const safeShares = (input: string): bigint => {
  try {
    return parseShares(input || '0');
  } catch {
    return 0n;
  }
};

const safePrice = (input: string): bigint => {
  try {
    return parsePrice(input || '0');
  } catch {
    return 0n;
  }
};

/** Turn a contract revert into something a person can act on. */
export function readableError(error: unknown): string {
  const message = (error as Error)?.message ?? String(error);
  if (/NoBid/.test(message)) return 'Nobody is bidding on that series right now. Try a price nearer today’s, or a longer wait.';
  if (/BadStrike/.test(message)) return 'That price is too far from where the stock is trading.';
  if (/BadExpiry/.test(message)) return 'That date is not one this venue offers.';
  if (/PremiumTooLow/.test(message)) return 'The price moved while you were signing. Check the new quote and try again.';
  if (/PriceUnavailable|NotUsable/.test(message)) return 'The venue will not price this ticker right now. It is usually a halt.';
  if (/AssetDisabled/.test(message)) return 'This ticker is not enabled on the venue.';
  if (/User rejected|denied/i.test(message)) return 'You cancelled that in your wallet.';
  if (/insufficient funds/i.test(message)) return 'Not enough balance to cover that.';
  return message.split('\n')[0].slice(0, 220);
}
