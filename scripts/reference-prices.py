#!/usr/bin/env python3
"""Regenerate every expected value in contracts/test/OptionMath.t.sol.

The Solidity implementation is a fixed-point approximation. Testing it against values it produced
itself proves nothing, so the expectations come from here: textbook Black-Scholes evaluated in IEEE
double precision against libm's erf, with no shared code path.

    python3 scripts/reference-prices.py
"""

import math

WAD = 10**18


def wad(x: float) -> int:
    return int(round(x * WAD))


def cdf(x: float) -> float:
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def black_scholes(spot: float, strike: float, tau: float, vol: float, rate: float):
    """Returns (call, put, call_delta) in the same units as spot."""
    pv_strike = strike * math.exp(-rate * tau)
    if tau == 0.0 or vol == 0.0:
        return max(spot - pv_strike, 0.0), max(pv_strike - spot, 0.0), 1.0 if spot >= strike else 0.0
    d1 = (math.log(spot / strike) + (rate + vol * vol / 2.0) * tau) / (vol * math.sqrt(tau))
    d2 = d1 - vol * math.sqrt(tau)
    call = spot * cdf(d1) - pv_strike * cdf(d2)
    put = pv_strike * cdf(-d2) - spot * cdf(-d1)
    return call, put, cdf(d1)


SECONDS_PER_YEAR = 31_557_600

CASES = [
    ("atTheMoneyOneYear", 100.0, 100.0, 1.0, 0.20, 0.05),
    ("outOfTheMoneyMonthlyCall", 180.0, 200.0, 30 * 86400 / SECONDS_PER_YEAR, 0.45, 0.04),
    ("inTheMoneyMonthlyCall", 180.0, 150.0, 30 * 86400 / SECONDS_PER_YEAR, 0.45, 0.04),
    ("shortDatedHighVol", 100.0, 100.0, 7 * 86400 / SECONDS_PER_YEAR, 0.60, 0.04),
    ("deepOutOfTheMoney", 50.0, 100.0, 1.0, 0.30, 0.05),
    ("deepInTheMoney", 200.0, 100.0, 0.5, 0.25, 0.03),
]


def main() -> None:
    print("normal CDF")
    for x in (0.0, 1.0, -1.96, 3.0, -3.0):
        print(f"  N({x:>6}) = {wad(cdf(x))}")

    print("\nblack-scholes")
    for name, spot, strike, tau, vol, rate in CASES:
        call, put, delta = black_scholes(spot, strike, tau, vol, rate)
        print(f"  {name}")
        print(f"    tau   = {wad(tau)}")
        print(f"    call  = {wad(call)}")
        print(f"    put   = {wad(put)}")
        print(f"    delta = {wad(delta)}")


if __name__ == "__main__":
    main()
