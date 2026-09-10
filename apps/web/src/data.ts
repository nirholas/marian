import type { Address } from 'viem';
import { paidordersAbi, assetregistryAbi, equityoracleAbi, creditlineAbi, termrepoAbi, accrualstripAbi, underwritervaultAbi } from '@marian/sdk';
import assetsJson from '@data/assets.json';
import accrualJson from '@data/accrual.json';
import type { Connection } from './chain.js';

export type Asset = {
  symbol: string;
  address: Address;
  decimals: number;
  pool: Address;
  fee: number;
  assetIsToken0: boolean;
  uiMultiplier: string;
  paused: boolean;
  oraclePaused: boolean;
  paysDistributions: boolean;
};

export type AccrualRow = {
  symbol: string;
  address: string;
  observed: boolean;
  stepsObserved?: number;
  observedDays?: number;
  cumulativeBps?: number;
  annualisedBps?: number;
  paysDistributions?: boolean;
};

/**
 * The static half of the app's data: what was measured off the chain by the scripts in `scripts/`,
 * checked into `data/` and shipped with the build.
 *
 * It is here rather than fetched at runtime because it is a *measurement*, not a live reading. The
 * accrual history in particular took several thousand archive calls to reconstruct and cannot be
 * rebuilt in a page load, and quoting a live guess in its place is precisely the dishonest screen
 * this product must not have.
 */
export const ASSETS = (assetsJson.assets as Asset[]).filter((a) => !a.paused && !a.oraclePaused);
export const ASSETS_MEASURED_AT = assetsJson.measuredAt as string;
export const ACCRUAL = accrualJson.tickers as AccrualRow[];
export const ACCRUAL_MEASURED_AT = accrualJson.measuredAt as string;

export const assetBySymbol = (symbol: string): Asset | undefined =>
  ASSETS.find((a) => a.symbol.toUpperCase() === symbol.toUpperCase());

export const accrualFor = (symbol: string): AccrualRow | undefined =>
  ACCRUAL.find((a) => a.symbol.toUpperCase() === symbol.toUpperCase());

/** Live state for one ticker, read fresh. Anything that decides money comes from here. */
export type LiveAsset = {
  spot1e8: bigint;
  multiplier: bigint;
  paused: boolean;
  oraclePaused: boolean;
};

const STOCK_ABI = [
  { type: 'function', name: 'uiMultiplier', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  { type: 'function', name: 'paused', inputs: [], outputs: [{ type: 'bool' }], stateMutability: 'view' },
  { type: 'function', name: 'oraclePaused', inputs: [], outputs: [{ type: 'bool' }], stateMutability: 'view' },
  { type: 'function', name: 'balanceOf', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
] as const;

export async function readLiveAsset(connection: Connection, asset: Asset): Promise<LiveAsset> {
  const { client, deployment } = connection;
  const [multiplier, paused, oraclePaused] = await Promise.all([
    client.readContract({ address: asset.address, abi: STOCK_ABI, functionName: 'uiMultiplier' }),
    client.readContract({ address: asset.address, abi: STOCK_ABI, functionName: 'paused' }),
    client.readContract({ address: asset.address, abi: STOCK_ABI, functionName: 'oraclePaused' }),
  ]);

  let spot1e8 = 0n;
  if (deployment) {
    // The oracle is the protocol's own opinion of the price, including its refusals. Reading the
    // pool directly here would show a number the venue itself would decline to trade on.
    spot1e8 = (await client.readContract({
      address: deployment.oracle,
      abi: equityoracleAbi,
      functionName: 'tryValueOf',
      args: [asset.address, 10n ** 18n],
    }).then((r) => (r as [bigint, boolean, number])[1] ? (r as [bigint, boolean, number])[0] : 0n)) as bigint;
  }

  return { spot1e8, multiplier: multiplier as bigint, paused: paused as boolean, oraclePaused: oraclePaused as boolean };
}

export async function readBalance(connection: Connection, token: Address, owner: Address): Promise<bigint> {
  return (await connection.client.readContract({
    address: token,
    abi: STOCK_ABI,
    functionName: 'balanceOf',
    args: [owner],
  })) as bigint;
}

export { paidordersAbi, assetregistryAbi, equityoracleAbi, creditlineAbi, termrepoAbi, accrualstripAbi, underwritervaultAbi, STOCK_ABI };
