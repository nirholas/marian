/** Minimal batched JSON-RPC against Robinhood Chain, shared by the scripts in this directory. */
export const RPCS = [
  process.env.RHC_RPC_URL,
  'https://rpc-robinhood.blockmachine.io',
  'https://robinhood.api.pocket.network',
  'https://robinhood-rpc.publicnode.com',
].filter(Boolean);

/**
 * Endpoints that answer `eth_call` at a past block.
 *
 * `publicnode` serves only the tip and rejects anything older as an archive request, but it rejects
 * it *inside a batch* as a null result rather than as an error, so a historical sweep that includes
 * it comes back full of holes that look like "this contract did not exist yet". Anything pinned to a
 * block number goes here instead.
 */
export const ARCHIVE_RPCS = [
  process.env.RHC_ARCHIVE_RPC_URL,
  'https://rpc-robinhood.blockmachine.io',
  'https://robinhood.api.pocket.network',
].filter(Boolean);

import { toFunctionSelector } from 'viem';

/**
 * Selectors, derived rather than pinned. Three of these were originally written out by hand and
 * three of those three were wrong (`newUIMultiplier`, `effectiveAt` and `oraclePaused` all hash to
 * something other than the obvious guess), which produces empty return data rather than an error
 * and reads downstream as "this token has no such field".
 */
export const SEL = Object.fromEntries(
  [
    ['symbol', 'function symbol() returns (string)'],
    ['decimals', 'function decimals() returns (uint8)'],
    ['totalSupply', 'function totalSupply() returns (uint256)'],
    ['uiMultiplier', 'function uiMultiplier() returns (uint256)'],
    ['newUIMultiplier', 'function newUIMultiplier() returns (uint256)'],
    ['effectiveAt', 'function effectiveAt() returns (uint256)'],
    ['paused', 'function paused() returns (bool)'],
    ['oraclePaused', 'function oraclePaused() returns (bool)'],
    ['token0', 'function token0() returns (address)'],
    ['token1', 'function token1() returns (address)'],
    ['fee', 'function fee() returns (uint24)'],
    ['slot0', 'function slot0() returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'],
    ['balanceOf', 'function balanceOf(address) returns (uint256)'],
  ].map(([name, signature]) => [name, toFunctionSelector(signature)]),
);

let cursor = 0;

/**
 * Send a batch of `eth_call`s. Rotates endpoints and retries, because these public RPCs rate-limit
 * under concurrency and a swept measurement that silently drops rows is worse than a slow one.
 */
export async function ethCallBatch(calls, { retries = 5, archive = false, requireAll = false } = {}) {
  if (calls.length === 0) return [];
  const pool = archive ? ARCHIVE_RPCS : RPCS;
  let lastError;
  for (let attempt = 0; attempt < retries; attempt++) {
    const url = pool[cursor++ % pool.length];
    const body = calls.map((c, i) => ({
      jsonrpc: '2.0',
      id: i,
      method: 'eth_call',
      params: [{ to: c.to, data: c.data }, c.block ?? 'latest'],
    }));
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      const json = await response.json();
      if (Array.isArray(json)) {
        const results = json.sort((a, b) => a.id - b.id).map((r) => r.result ?? null);
        // A partially-null batch is an endpoint declining, not a chain fact. Retrying elsewhere is
        // the difference between a measurement and a guess.
        if (!requireAll || results.every((r) => r !== null && r !== '0x')) return results;
        lastError = new Error(`${results.filter((r) => r === null || r === '0x').length} empty results`);
      } else {
        lastError = new Error(json?.error?.message ?? 'non-array batch response');
      }
    } catch (error) {
      lastError = error;
    }
    await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
  }
  throw new Error(`RPC batch failed after ${retries} attempts: ${lastError?.message ?? 'unknown'}`);
}

export async function rpc(method, params, { retries = 4 } = {}) {
  let lastError;
  for (let attempt = 0; attempt < retries; attempt++) {
    const url = RPCS[cursor++ % RPCS.length];
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      });
      const json = await response.json();
      if (json.result !== undefined) return json.result;
      lastError = new Error(json?.error?.message ?? 'no result');
    } catch (error) {
      lastError = error;
    }
    await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
  }
  throw new Error(`${method} failed after ${retries} attempts: ${lastError?.message ?? 'unknown'}`);
}

export const toBigInt = (hex) => (hex && hex !== '0x' ? BigInt(hex) : null);
export const toAddress = (hex) => (hex && hex.length >= 66 ? '0x' + hex.slice(26, 66) : null);

export function decodeString(hex) {
  if (!hex || hex === '0x') return null;
  const body = hex.slice(2);
  const length = parseInt(body.slice(64, 128), 16);
  const chars = body.slice(128, 128 + length * 2);
  return Buffer.from(chars, 'hex').toString('utf8');
}
