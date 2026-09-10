import { WAD } from './units.js';

/**
 * Helpers for the covered-call and cash-secured-put venue that do not need a chain round trip.
 *
 * Anything that decides money is read from the contract. What lives here is the arithmetic a UI
 * needs before the user has committed to anything: which dates are selectable, what a strike is
 * called, and what the trade actually caps out at.
 */

/** Friday 2026-01-02 20:00:00 UTC, the anchor of the weekly expiry grid. Matches `PaidOrders`. */
export const EXPIRY_EPOCH = 1_767_384_000;
export const EXPIRY_PERIOD = 7 * 24 * 60 * 60;

export const isValidExpiry = (expiry: number): boolean =>
  expiry > EXPIRY_EPOCH && (expiry - EXPIRY_EPOCH) % EXPIRY_PERIOD === 0;

/** The next `count` weekly expiries after `now`, in unix seconds. */
export function upcomingExpiries(count: number, now = Math.floor(Date.now() / 1000)): number[] {
  const elapsed = Math.max(0, now - EXPIRY_EPOCH);
  const first = EXPIRY_EPOCH + (Math.floor(elapsed / EXPIRY_PERIOD) + 1) * EXPIRY_PERIOD;
  return Array.from({ length: count }, (_, i) => first + i * EXPIRY_PERIOD);
}

/** "3 weeks" rather than a date, because the user chose how long to wait, not when to stop. */
export function describeWait(expiry: number, now = Math.floor(Date.now() / 1000)): string {
  const days = Math.max(0, Math.round((expiry - now) / 86_400));
  if (days === 0) return 'today';
  if (days === 1) return '1 day';
  if (days < 14) return `${days} days`;
  const weeks = Math.round(days / 7);
  return weeks === 1 ? '1 week' : `${weeks} weeks`;
}

/**
 * The whole outcome of a covered call, in the two numbers a writer has to see together.
 *
 * The premium alone is a half-truth: it is the part that always happens, and showing it without
 * the cap is what makes a writer feel cheated the first time the stock gaps through their strike.
 * `maxProceeds` is the ceiling, `upsideForgone` is what a gap past the strike costs them, and both
 * belong on the same screen as the premium in the same unit.
 */
export type CallOutcome = {
  premiumUsdg: bigint;
  maxProceedsUsdg: bigint;
  breakEvenPrice1e8: bigint;
  upsideForgoneAt: (settlePrice1e8: bigint) => bigint;
};

export function coveredCallOutcome(args: {
  qtyRaw: bigint;
  strikePerShare1e8: bigint;
  spotPerShare1e8: bigint;
  multiplier: bigint;
  premiumUsdg: bigint;
  usdgOne: bigint;
  rawOne: bigint;
  priceOne: bigint;
}): CallOutcome {
  const { qtyRaw, strikePerShare1e8, premiumUsdg, usdgOne, rawOne, priceOne, multiplier } = args;
  const strikeRaw = (strikePerShare1e8 * multiplier) / WAD;
  const value = (price1e8: bigint) => (qtyRaw * price1e8 * usdgOne) / (rawOne * priceOne);

  const maxProceedsUsdg = value(strikeRaw) + premiumUsdg;
  // Below this settlement price the writer is better off than having simply held.
  const breakEvenPrice1e8 = args.spotPerShare1e8;

  return {
    premiumUsdg,
    maxProceedsUsdg,
    breakEvenPrice1e8,
    upsideForgoneAt: (settlePrice1e8: bigint) => {
      const settleRaw = (settlePrice1e8 * multiplier) / WAD;
      if (settleRaw <= strikeRaw) return 0n;
      const forgone = value(settleRaw) - value(strikeRaw);
      return forgone > premiumUsdg ? forgone - premiumUsdg : 0n;
    },
  };
}

/** The same for a cash-secured put: the cash it locks, and what it costs if the stock collapses. */
export function cashSecuredPutOutcome(args: {
  qtyRaw: bigint;
  strikePerShare1e8: bigint;
  multiplier: bigint;
  premiumUsdg: bigint;
  usdgOne: bigint;
  rawOne: bigint;
  priceOne: bigint;
}) {
  const { qtyRaw, strikePerShare1e8, multiplier, premiumUsdg, usdgOne, rawOne, priceOne } = args;
  const strikeRaw = (strikePerShare1e8 * multiplier) / WAD;
  const value = (price1e8: bigint) => (qtyRaw * price1e8 * usdgOne) / (rawOne * priceOne);

  return {
    premiumUsdg,
    /** Dollars the writer sets aside. Exactly what the shares would cost at their price. */
    cashLockedUsdg: value(strikeRaw),
    /** The worst case is the stock going to zero, which is the same worst case as owning it. */
    worstCaseLossUsdg: value(strikeRaw) - premiumUsdg,
    lossAt: (settlePrice1e8: bigint) => {
      const settleRaw = (settlePrice1e8 * multiplier) / WAD;
      if (settleRaw >= strikeRaw) return 0n;
      const loss = value(strikeRaw) - value(settleRaw);
      return loss > premiumUsdg ? loss - premiumUsdg : 0n;
    },
  };
}
