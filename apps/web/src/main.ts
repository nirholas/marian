import './styles.css';
import { connect, connectWallet, currentWallet, hasInjectedProvider, onWalletChange, type Connection } from './chain.js';
import { abbreviate } from './format.js';
import { escapeHtml, notice } from './components.js';
import { renderHome } from './pages/home.js';
import { mountPaid } from './pages/paid.js';
import { mountBorrow } from './pages/borrow.js';
import { mountSavings } from './pages/savings.js';
import { mountPayouts } from './pages/payouts.js';

const ROUTES = [
  { path: '#/', label: 'Overview' },
  { path: '#/paid', label: 'Paid orders' },
  { path: '#/borrow', label: 'Borrow' },
  { path: '#/savings', label: 'Savings' },
  { path: '#/payouts', label: 'Payouts' },
];

const app = document.querySelector<HTMLElement>('#app')!;

async function boot() {
  app.innerHTML = shell('<div class="stack"><div class="skeleton" style="height:36px;width:60%"></div><div class="skeleton" style="height:120px"></div></div>', null);

  let connection: Connection;
  try {
    connection = await connect();
  } catch (error) {
    app.innerHTML = shell(
      notice(
        `<div><strong>Could not reach the chain.</strong> ${escapeHtml((error as Error).message)}</div>`,
        'danger',
      ),
      null,
    );
    return;
  }

  app.removeAttribute('aria-busy');

  const paint = () => {
    const route = location.hash || '#/';
    app.innerHTML = shell('<div id="page"></div>', connection);
    const page = app.querySelector<HTMLElement>('#page')!;

    switch (route) {
      case '#/paid':
        mountPaid(page, connection);
        break;
      case '#/borrow':
        mountBorrow(page, connection);
        break;
      case '#/savings':
        mountSavings(page, connection);
        break;
      case '#/payouts':
        mountPayouts(page, connection);
        break;
      default:
        page.innerHTML = renderHome(connection);
    }

    app.querySelector<HTMLButtonElement>('#connect')?.addEventListener('click', async () => {
      try {
        await connectWallet(connection);
      } catch (error) {
        const bar = app.querySelector<HTMLElement>('.wallet');
        if (bar) bar.textContent = (error as Error).message;
      }
    });
  };

  window.addEventListener('hashchange', paint);
  onWalletChange(paint);
  paint();
}

function shell(body: string, connection: Connection | null): string {
  const route = location.hash || '#/';
  const wallet = currentWallet();

  return `
    <div class="shell">
      <header class="topbar">
        <a class="brand" href="#/">Marian<small>tokenized equities, one sentence each</small></a>
        <nav class="nav">
          ${ROUTES.map(
            (r) => `<a href="${r.path}"${r.path === route ? ' aria-current="page"' : ''}>${escapeHtml(r.label)}</a>`,
          ).join('')}
        </nav>
        <div class="wallet">
          ${connection
            ? `<span class="dot ${connection.deployment ? 'live' : ''}" title="${escapeHtml(connection.label)}"></span>
               <span class="faint">${escapeHtml(connection.label)}</span>`
            : ''}
          ${wallet
            ? `<span class="mono">${escapeHtml(abbreviate(wallet.address))}</span>`
            : hasInjectedProvider()
              ? '<button class="chip" id="connect">Connect wallet</button>'
              : '<span class="faint">No wallet extension</span>'}
        </div>
      </header>
      <main>${body}</main>
      <footer>
        <span>Marian runs on Robinhood Chain (eip155:4663).</span>
        <span>Every number on this site was read from the chain or measured from its history.</span>
      </footer>
    </div>`;
}

void boot();
