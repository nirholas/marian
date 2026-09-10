import { parseUsdg, USDG_ONE } from '@marian/sdk';
import { escapeHtml, figureRow, notice, emptyState } from '../components.js';
import { usd, percent } from '../format.js';
import { termrepoAbi } from '../data.js';
import { connectWallet, currentWallet, type Connection } from '../chain.js';
import { readableError } from './paid.js';

type Term = { seconds: number; aprBps: number };

type State = {
  terms: Term[] | null;
  selected: number;
  amountInput: string;
  busy: boolean;
  status: string;
  error: string;
};

const SECONDS_PER_YEAR = 31_557_600;

export function mountSavings(root: HTMLElement, connection: Connection) {
  const state: State = { terms: null, selected: 0, amountInput: '10000', busy: false, status: '', error: '' };

  async function refresh() {
    if (!connection.deployment) {
      state.terms = [];
      return render();
    }
    try {
      const lengths = (await connection.client.readContract({
        address: connection.deployment.termRepo,
        abi: termrepoAbi,
        functionName: 'terms',
      })) as readonly number[];

      const terms: Term[] = [];
      for (const seconds of lengths) {
        const aprBps = (await connection.client.readContract({
          address: connection.deployment.termRepo,
          abi: termrepoAbi,
          functionName: 'aprForTerm',
          args: [seconds],
        })) as number;
        if (Number(aprBps) > 0) terms.push({ seconds: Number(seconds), aprBps: Number(aprBps) });
      }
      terms.sort((a, b) => a.seconds - b.seconds);
      state.terms = terms;
      state.selected = 0;
    } catch (error) {
      state.error = readableError(error);
      state.terms = [];
    }
    render();
  }

  async function submit() {
    if (!connection.deployment || !state.terms?.length) return;
    state.busy = true;
    state.error = '';
    try {
      const wallet = currentWallet() ?? (await connectWallet(connection));
      const amount = parseUsdg(state.amountInput);
      const term = state.terms[state.selected];

      state.status = 'Approving the dollars';
      render();
      await wallet.client.writeContract({
        account: wallet.address,
        chain: null,
        address: USDG_ADDRESS,
        abi: APPROVE_ABI,
        functionName: 'approve',
        args: [connection.deployment.termRepo, amount],
      });

      state.status = 'Placing the deposit';
      render();
      const hash = await wallet.client.writeContract({
        account: wallet.address,
        chain: null,
        address: connection.deployment.termRepo,
        abi: termrepoAbi,
        functionName: 'lend',
        args: [amount, term.seconds],
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
    root.querySelectorAll<HTMLElement>('[data-term]').forEach((node) =>
      node.addEventListener('click', () => {
        state.selected = Number(node.dataset.term);
        render();
      }),
    );
    root.querySelector<HTMLInputElement>('#amount')?.addEventListener('input', (event) => {
      state.amountInput = (event.target as HTMLInputElement).value;
      render();
    });
    root.querySelector<HTMLButtonElement>('#submit')?.addEventListener('click', () => void submit());
  }

  void refresh();
}

const USDG_ADDRESS = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168' as const;
const APPROVE_ABI = [
  { type: 'function', name: 'approve', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }], stateMutability: 'nonpayable' },
] as const;

const describeTerm = (seconds: number): string => {
  const days = Math.round(seconds / 86_400);
  if (days % 365 === 0) return `${days / 365} year${days > 365 ? 's' : ''}`;
  if (days % 30 === 0) return `${days / 30} months`;
  return `${days} days`;
};

function view(connection: Connection, state: State): string {
  const amount = (() => {
    try {
      return parseUsdg(state.amountInput || '0');
    } catch {
      return 0n;
    }
  })();

  const term = state.terms?.[state.selected];
  const interest = term ? (amount * BigInt(term.aprBps) * BigInt(term.seconds)) / (10_000n * BigInt(SECONDS_PER_YEAR)) : 0n;

  return `
    <p class="eyebrow">Fixed-term savings</p>
    <h1>Lock dollars. Earn a fixed rate.</h1>
    <p class="lede">
      Choose how long, see exactly what you will be paid, and get it. Not a floating rate that drifts
      and not an average that hides a bad month: the whole term's interest is put into escrow the
      moment a borrower takes your deposit, so from that instant it is a balance rather than a
      forecast.
    </p>

    ${connection.deployment ? '' : notice(
      '<div><strong>No deployment on this network.</strong> Run <code>node scripts/demo.mjs</code> to bring one up against a fork of the real chain.</div>',
      'warn',
    )}

    ${state.terms === null
      ? '<div class="card"><div class="skeleton" style="height:80px"></div></div>'
      : state.terms.length === 0
        ? emptyState(
            'No terms are open',
            'A term opens when the venue posts a rate for it. On a local deployment, <code>scripts/demo.mjs</code> opens 30, 90 and 180 days.',
          )
        : `
    <div class="split">
      <form class="form card" onsubmit="return false">
        <div class="field">
          <label>How long</label>
          <div class="chips">
            ${state.terms
              .map(
                (t, i) =>
                  `<button type="button" class="chip" data-term="${i}" aria-pressed="${i === state.selected}">${escapeHtml(describeTerm(t.seconds))} &middot; ${percent(t.aprBps, 2)}</button>`,
              )
              .join('')}
          </div>
        </div>

        <div class="field">
          <label for="amount">How much</label>
          <div class="control">
            <span class="prefix">$</span>
            <input id="amount" inputmode="decimal" value="${escapeHtml(state.amountInput)}" />
          </div>
          <span class="hint">In USDG. You can take it back at any time until it is matched.</span>
        </div>

        <button class="btn" id="submit" ${state.busy || amount === 0n ? 'disabled' : ''}>
          ${state.busy ? escapeHtml(state.status || 'Working...') : `Lock ${usd(amount)}`}
        </button>
        ${state.status && !state.busy ? notice(`<div>${escapeHtml(state.status)}</div>`) : ''}
        ${state.error ? notice(`<div>${escapeHtml(state.error)}</div>`, 'warn') : ''}
      </form>

      <div class="stack">
        ${figureRow([
          {
            label: 'You will be paid',
            value: usd(interest),
            qualifier: term ? `on ${usd(amount)} over ${describeTerm(term.seconds)}` : '',
            tone: 'good',
          },
          {
            label: 'Back at the end',
            value: usd(amount + interest),
            qualifier: 'principal and interest together',
            tone: 'plain',
          },
        ])}

        ${notice(
          `<div><strong>The one thing to understand.</strong> Your deposit earns nothing until a
           borrower takes it. Until then it sits here and you can withdraw it in full, with no
           penalty and no notice. Once taken, the borrower has already paid the entire term's
           interest into this contract and posted more than the deposit's value in shares against
           it, so the rate above stops being a promise and starts being an escrow balance.</div>`,
        )}

        ${notice(
          `<div><strong>What backs it.</strong> Every borrower posts tokenized equity worth
           substantially more than they take, sized with an extra buffer for the possibility that
           the issuer freezes the collateral. If a borrower does not repay, anyone can pay the
           principal and take the collateral, which is what makes you whole.</div>`,
        )}
      </div>
    </div>`}`;
}
