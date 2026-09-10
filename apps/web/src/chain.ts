import { createPublicClient, createWalletClient, custom, http, type Address, type PublicClient, type WalletClient } from 'viem';
import { robinhoodChain, DEPLOYMENTS, type Deployment } from '@marian/sdk';

/**
 * Which chain this build talks to, and whether the protocol exists there.
 *
 * There are exactly two supported situations and the interface says which one it is in rather than
 * pretending: a local fork brought up by `node scripts/demo.mjs`, or Robinhood Chain itself once a
 * deployment lands. A build pointed at a chain with no deployment renders a designed explanation of
 * how to get one, not a blank screen or a spinner that never resolves.
 */
export type Connection = {
  chainId: number;
  rpcUrl: string;
  label: string;
  deployment: Deployment | null;
  client: PublicClient;
};

const DEMO_RPC = import.meta.env.VITE_DEMO_RPC ?? 'http://127.0.0.1:8599';

export async function connect(): Promise<Connection> {
  // The local fork wins when it is up, because a developer who just ran the demo means to look at
  // the demo. Probing is one request and it fails fast.
  //
  // Its chain id is read rather than assumed: an anvil that forks adopts the forked chain's id, so
  // a local node here reports 4663 and not 31337. Hardcoding the latter files the deployment under
  // an id nothing ever asks for, and the app renders "not deployed" while talking to it happily.
  const local = await probe(DEMO_RPC);
  if (local !== null && DEPLOYMENTS[local]) {
    return {
      chainId: local,
      rpcUrl: DEMO_RPC,
      label: 'Local fork of Robinhood Chain',
      deployment: DEPLOYMENTS[local]!,
      client: createPublicClient({ transport: http(DEMO_RPC) }) as PublicClient,
    };
  }

  const rpcUrl = robinhoodChain.rpcUrls.default.http[0];
  return {
    chainId: robinhoodChain.id,
    rpcUrl,
    label: 'Robinhood Chain',
    deployment: DEPLOYMENTS[robinhoodChain.id] ?? null,
    client: createPublicClient({ chain: robinhoodChain, transport: http(rpcUrl) }) as PublicClient,
  };
}

async function probe(url: string): Promise<number | null> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1200);
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    const json = await response.json();
    return json?.result ? Number(json.result) : null;
  } catch {
    return null;
  }
}

export type Wallet = { address: Address; client: WalletClient };

let wallet: Wallet | null = null;
const walletListeners = new Set<(w: Wallet | null) => void>();

export const currentWallet = (): Wallet | null => wallet;

export function onWalletChange(listener: (w: Wallet | null) => void): () => void {
  walletListeners.add(listener);
  return () => walletListeners.delete(listener);
}

function setWallet(next: Wallet | null) {
  wallet = next;
  for (const listener of walletListeners) listener(next);
}

export function hasInjectedProvider(): boolean {
  return typeof window !== 'undefined' && 'ethereum' in window;
}

/** Connect an injected wallet. Throws with a message meant to be shown to a person. */
export async function connectWallet(connection: Connection): Promise<Wallet> {
  const injected = (window as unknown as { ethereum?: any }).ethereum;
  if (!injected) throw new Error('No wallet extension found in this browser.');

  const accounts: Address[] = await injected.request({ method: 'eth_requestAccounts' });
  if (!accounts?.length) throw new Error('The wallet returned no accounts.');

  const client = createWalletClient({ account: accounts[0], transport: custom(injected) });
  const next = { address: accounts[0], client };
  setWallet(next);

  injected.on?.('accountsChanged', (list: Address[]) => {
    if (!list?.length) return setWallet(null);
    setWallet({ address: list[0], client: createWalletClient({ account: list[0], transport: custom(injected) }) });
  });

  const walletChain = Number(await injected.request({ method: 'eth_chainId' }));
  if (walletChain !== connection.chainId) {
    throw new Error(
      `Your wallet is on chain ${walletChain} but this page is reading chain ${connection.chainId}. ` +
        'Switch networks and reconnect.',
    );
  }
  return next;
}

export function disconnectWallet() {
  setWallet(null);
}
