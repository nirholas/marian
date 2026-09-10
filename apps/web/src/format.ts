import { formatUsdg, formatPrice, formatShares, USDG_ONE, PRICE_ONE } from '@marian/sdk';

export const usd = (value: bigint, decimals = 2): string => `$${withCommas(formatUsdg(value, decimals))}`;

export const price = (value: bigint, decimals = 2): string => `$${withCommas(formatPrice(value, decimals))}`;

export const shares = (value: bigint, decimals = 4): string => withCommas(formatShares(value, decimals));

export const percent = (bps: number, decimals = 2): string => `${(bps / 100).toFixed(decimals)}%`;

export function withCommas(input: string): string {
  const [whole, fraction] = input.split('.');
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return fraction === undefined ? grouped : `${grouped}.${fraction}`;
}

/** "in 3 weeks", "in 4 days". A user picked how long to wait, not a calendar date. */
export function relativeTime(unixSeconds: number, now = Date.now() / 1000): string {
  const delta = unixSeconds - now;
  const past = delta < 0;
  const days = Math.abs(delta) / 86_400;
  const body =
    days < 1
      ? `${Math.max(1, Math.round(Math.abs(delta) / 3600))} hours`
      : days < 14
        ? `${Math.round(days)} days`
        : `${Math.round(days / 7)} weeks`;
  return past ? `${body} ago` : `in ${body}`;
}

export function calendarDate(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleDateString(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  });
}

export const abbreviate = (address: string): string => `${address.slice(0, 6)}...${address.slice(-4)}`;

export { USDG_ONE, PRICE_ONE };
