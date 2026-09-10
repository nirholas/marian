/**
 * The three units this protocol mixes, and the conversions between them.
 *
 * Getting these wrong is the single most likely way to build a client that looks right and is off
 * by a factor of a trillion, so they live in one file with names that say what they are:
 *
 * - **raw**: a tokenized equity's own smallest unit. 18 decimals. NOT a share.
 * - **usdg**: dollars as USDG holds them. 6 decimals.
 * - **price**: dollars at 1e8, the unit every oracle and strike in the protocol uses.
 *
 * And one that is not a unit at all but a scale factor: `uiMultiplier`, the number of economic
 * shares one raw unit carries, at 1e18. A user thinks in shares; the chain stores raw units; the
 * multiplier is the only thing that relates them, and it moves.
 */
export const RAW_DECIMALS = 18;
export const USDG_DECIMALS = 6;
export const PRICE_DECIMALS = 8;

export const RAW_ONE = 10n ** BigInt(RAW_DECIMALS);
export const USDG_ONE = 10n ** BigInt(USDG_DECIMALS);
export const PRICE_ONE = 10n ** BigInt(PRICE_DECIMALS);
export const WAD = 10n ** 18n;

/** Economic shares carried by `raw` raw units at the given multiplier, as a wad. */
export const sharesFromRaw = (raw: bigint, multiplier: bigint): bigint => (raw * multiplier) / WAD;

/** Raw units needed to carry `shares` economic shares. Rounds up, so an escrow is never short. */
export const rawFromShares = (shares: bigint, multiplier: bigint): bigint =>
  multiplier === 0n ? 0n : (shares * WAD + multiplier - 1n) / multiplier;

/** Dollars per economic share, at 1e8, converted to the per-raw-unit strike the protocol stores. */
export const strikePerShareToRaw = (perShare: bigint, multiplier: bigint): bigint =>
  (perShare * multiplier) / WAD;

export const strikeRawToPerShare = (perRaw: bigint, multiplier: bigint): bigint =>
  multiplier === 0n ? 0n : (perRaw * WAD) / multiplier;

/** USDG value of `raw` raw units priced at `price1e8` per whole token. */
export const usdgValue = (raw: bigint, price1e8: bigint): bigint =>
  (raw * price1e8 * USDG_ONE) / (RAW_ONE * PRICE_ONE);

/** Parse a human dollar string into USDG's 6 decimals without going through a float. */
export function parseUsdg(input: string): bigint {
  return parseFixed(input, USDG_DECIMALS);
}

/** Parse a human dollar string into the protocol's 1e8 price unit. */
export function parsePrice(input: string): bigint {
  return parseFixed(input, PRICE_DECIMALS);
}

/** Parse a human share count into raw units. */
export function parseShares(input: string): bigint {
  return parseFixed(input, RAW_DECIMALS);
}

function parseFixed(input: string, decimals: number): bigint {
  const trimmed = input.trim().replace(/,/g, '');
  if (!/^-?\d*(\.\d*)?$/.test(trimmed) || trimmed === '' || trimmed === '.') {
    throw new Error(`not a number: ${input}`);
  }
  const negative = trimmed.startsWith('-');
  const [whole, fraction = ''] = (negative ? trimmed.slice(1) : trimmed).split('.');
  // Truncate rather than round. A client that rounds a strike up by a hundredth of a cent asks for
  // a series the user did not name.
  const padded = (fraction + '0'.repeat(decimals)).slice(0, decimals);
  const value = BigInt((whole || '0') + padded);
  return negative ? -value : value;
}

/** Format a fixed-point value for display, with a fixed number of visible decimals. */
export function formatFixed(value: bigint, decimals: number, displayDecimals = 2): string {
  const unit = 10n ** BigInt(decimals);
  const negative = value < 0n;
  const absolute = negative ? -value : value;
  const whole = absolute / unit;
  const fraction = absolute % unit;
  const shown = (fraction * 10n ** BigInt(displayDecimals)) / unit;
  const body = displayDecimals === 0
    ? whole.toString()
    : `${whole.toString()}.${shown.toString().padStart(displayDecimals, '0')}`;
  return negative ? `-${body}` : body;
}

export const formatUsdg = (value: bigint, displayDecimals = 2): string =>
  formatFixed(value, USDG_DECIMALS, displayDecimals);

export const formatPrice = (value: bigint, displayDecimals = 2): string =>
  formatFixed(value, PRICE_DECIMALS, displayDecimals);

export const formatShares = (value: bigint, displayDecimals = 4): string =>
  formatFixed(value, RAW_DECIMALS, displayDecimals);
