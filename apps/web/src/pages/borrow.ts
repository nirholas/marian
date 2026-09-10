import { parseShares, parseUsdg, RAW_ONE, USDG_ONE, WAD } from '@marian/sdk';
import { escapeHtml, figureRow, notice, emptyState } from '../components.js';
import { usd, price as fmtPrice, percent } from '../format.js';
import { ASSETS, assetBySymbol, readLiveAsset, readBalance, creditlineAbi, assetregistryAbi, STOCK_ABI, type Asset, type LiveAsset } from '../data.js';
import { connectWallet, currentWallet, type Connection } from '../chain.js';
import { readableError } from './paid.js';

type State = {
  symbol: string;
  sharesInput: string;
  live: LiveAsset | null;
  capacity: bigint | null;
  config: { maxLtvBps: number; haltBufferBps: number } | null;
  held: bigint | null;
  busy: boolean;
  status: string;
  error: string;
};

export function mountBorrow(root: HTMLElement, connection: Connection) {
  const first = ASSETS[0];
  if (!first) {
    root.innerHTML = emptyState('No tickers available', 'Run <code>node scripts/refresh-assets.mjs</code> first.');
    return;
  }

  const state: State = {
    symbol: first.symbol,
    sharesInput: '100',
    live: null,
    capacity: null,
    config: null,
    held: null,
    busy: false,
    status: '',
    error: '',
  };

  const asset = (): Asset => assetBySymbol(state.symbol) ?? first;

  async function refresh() {
    state.live = null;
    state.config = null;
    render();
    try {
      state.live = await readLiveAsset(connection, asset());
      if (connection.deployment) {
        const config = (await connection.client.readContract({
          address: connection.deployment.registry,
          abi: assetregistryAbi,
          functionName: 'configOf',
          args: [asset().address],
        })) as any;
        state.config = { maxLtvBps: Number(config.maxLtvBps), haltBufferBps: Number(config.haltBufferBps) };
      }
      const wallet = currentWallet();
      if (wallet) state.held = await readBalance(connection, asset().address, wallet.address);
    } catch (error) {
      state.error = readableError(error);
    }
    render();
  }

  async function submit() {
    if (!connection.deployment) return;
    state.busy = true;
    state.error = '';
    try {
      const wallet = currentWallet() ?? (await connectWallet(connection));
      const qtyRaw = parseShares(state.sharesInput);
      state.status = 'Approving the shares';
      render();
      await wallet.client.writeContract({
        account: wallet.address,
        chain: null,
        address: asset().address,
        abi: APPROVE_ABI,
        functionName: 'approve',
        args: [connection.deployment.creditLine, qtyRaw],
      });

      const capacity = cashAvailable(state);
      state.status = 'Locking the shares and sending the cash';
      render();
      const hash = await wallet.client.writeContract({
        account: wallet.address,
        chain: null,
        address: connection.deployment.creditLine,
        abi: creditlineAbi,
        functionName: 'borrowAgainst',
        args: [asset().address, qtyRaw, capacity],
      });
      state.status = `Done. ${hash.slice(0, 10)}...`;
    } catch (error) {
      state.error = readableError(error);
      state.status = '';
    }
    state.busy = false;
    render();
  }

  function render() {
    root.innerHTML = view(connection, state);
    root.querySelector<HTMLSelectElement>('#ticker')?.addEventListener('change', (event) => {
      state.symbol = (event.target as HTMLSelectElement).value;
      void refresh();
    });
    root.querySelector<HTMLInputElement>('#shares')?.addEventListener('input', (event) => {
      state.sharesInput = (event.target as HTMLInputElement).value;
      render();
    });
    root.querySelector<HTMLButtonElement>('#submit')?.addEventListener('click', () => void submit());
  }

  void refresh();
}

const APPROVE_ABI = [
  { type: 'function', name: 'approve', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }], stateMutability: 'nonpayable' },
] as const;

function collateralValue(state: State): bigint {
  const live = state.live;
  if (!live || live.spot1e8 === 0n) return 0n;
  let qtyRaw: bigint;
  try {
    qtyRaw = parseShares(state.sharesInput || '0');
  } catch {
    return 0n;
  }
  return (qtyRaw * live.spot1e8 * USDG_ONE) / (RAW_ONE * 10n ** 8n);
}

function cashAvailable(state: State): bigint {
  const value = collateralValue(state);
  if (!state.config || value === 0n) return 0n;
  const gross = (value * BigInt(state.config.maxLtvBps)) / 10_000n;
  return (gross * BigInt(10_000 - state.config.haltBufferBps)) / 10_000n;
}

function view(connection: Connection, state: State): string {
  const asset = assetBySymbol(state.symbol)!;
  const value = collateralValue(state);
  const cash = cashAvailable(state);
  const config = state.config;

  return `
    <p class="eyebrow">Borrow</p>
    <h1>Get cash without selling.</h1>
    <p class="lede">
      Lock shares, take dollars, pay them back whenever you like and take the shares out again. You
      keep every dividend, every split and every dollar the shares gain while they are locked. You
      never sell, so you never take the tax hit or give up the position.
    </p>

    ${connection.deployment ? '' : notice(
      '<div><strong>No deployment on this network.</strong> Run <code>node scripts/demo.mjs</code> to bring one up against a fork of the real chain.</div>',
      'warn',
    )}

    <div class="split">
      <form class="form card" onsubmit="return false">
        <div class="field">
          <label for="ticker">What you will lock</label>
          <div class="control">
            <select id="ticker">
              ${ASSETS.map((a) => `<option value="${a.symbol}"${a.symbol === state.symbol ? ' selected' : ''}>${escapeHtml(a.symbol)}</option>`).join('')}
            </select>
          </div>
          <span class="hint">
            ${state.live && state.live.spot1e8 > 0n ? `Trading at ${fmtPrice(state.live.spot1e8)} a share` : 'Reading the chain...'}
          </span>
        </div>

        <div class="field">
          <label for="shares">How many shares</label>
          <div class="control">
            <input id="shares" inputmode="decimal" value="${escapeHtml(state.sharesInput)}" />
            <span class="prefix">${escapeHtml(asset.symbol)}</span>
          </div>
          <span class="hint">${value > 0n ? `Worth ${usd(value)}` : 'Enter an amount'}</span>
        </div>

        <button class="btn" id="submit" ${state.busy || cash === 0n ? 'disabled' : ''}>
          ${state.busy ? escapeHtml(state.status || 'Working...') : cash > 0n ? `Get ${usd(cash)}` : 'Get cash'}
        </button>
        ${state.status && !state.busy ? notice(`<div>${escapeHtml(state.status)}</div>`) : ''}
        ${state.error ? notice(`<div>${escapeHtml(state.error)}</div>`, 'warn') : ''}
      </form>

      <div class="stack">
        ${figureRow([
          {
            label: 'Cash you can take',
            value: cash > 0n ? usd(cash) : '--',
            qualifier: config
              ? `${percent(config.maxLtvBps, 0)} of value, less a ${percent(config.haltBufferBps, 0)} halt buffer`
              : 'reading the venue',
            tone: 'good',
          },
          {
            label: 'What you keep',
            value: value > 0n ? usd(value) : '--',
            qualifier: 'the shares, and everything they do next',
            tone: 'plain',
          },
        ])}

        ${notice(
          `<div><strong>Why you cannot borrow the full value.</strong> The issuer of a tokenized
           equity can freeze it, and while it is frozen no transfer of it works at all: a lender
           cannot seize the collateral at any price, for a length of time nobody can promise in
           advance. ${config ? `The ${percent(config.haltBufferBps, 0)} buffer is what that costs.` : ''}
           It is the one risk here that has no equivalent on any other chain, and this is where it
           is priced rather than discovered.</div>`,
        )}

        ${notice(
          `<div><strong>Paying back.</strong> Interest accrues by the second, so "repay everything"
           means passing the maximum rather than a number you read a moment ago. Every client in
           this repo does that, and so should yours.</div>`,
        )}
      </div>
    </div>`;
}
