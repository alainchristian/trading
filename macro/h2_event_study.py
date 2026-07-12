"""
Step 5 (H2, rescoped): does realized return behave differently in fixed
windows following a scheduled high-impact release, vs. a random-window
baseline? See docs/phase-log.md for the pre-declared design and bar, locked
in before this script was written.

Currency/pair mapping (4 currencies tested, matching the pre-declared bar
exactly): EUR->EURUSD, GBP->GBPUSD, JPY->USDJPY, AUD->AUDUSD. USD isn't
tested standalone here since it has no single dedicated pair in this
project's scope (it appears in all three USD pairs) -- kept out of the
pre-declared "4 currencies" count rather than picked arbitrarily post hoc.

"High-impact" = the four category types themselves (cpi/employment/gdp/
rate_decision), NOT a further filter on MQL5's separate importance flag --
checked before running: AUD has zero MQL5-"high"-importance CPI/employment/
GDP events at all (only its rate decisions are flagged high), a broker-side
tagging inconsistency, not a real economic distinction. Filtering on
importance would gut AUD's sample for a reason that has nothing to do with
the hypothesis being tested.

Primary pre-declared window: 24H (matches H2's own "short-horizon drift"
framing). 1H/4H are computed and reported as supporting diagnostic context,
not part of the pass/fail bar -- decided now, before running, specifically
to avoid picking whichever of the 3 windows looks best after the fact.
"""
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg
from scipy.stats import mannwhitneyu

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
DATASET_DIR = Path("C:/trading/_mt5-instance/macro_dataset")
WINDOWS_HOURS = {"1H": 1, "4H": 4, "24H": 24}
PRIMARY_WINDOW = "24H"
EFFECT_SIZE_BAR = 1.5
PVALUE_BAR = 0.05
RANDOM_SEED = 42

CURRENCY_PAIR_MAP = {
    "EUR": "EURUSD",
    "GBP": "GBPUSD",
    "JPY": "USDJPY",
    "AUD": "AUDUSD",
}


def load_env():
    env = {}
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def load_events(conn, currency):
    df = pd.read_sql(
        "SELECT release_time FROM macro_calendar_events "
        "WHERE currency = %(currency)s "
        "AND event_category IN ('cpi','employment','gdp','rate_decision') "
        "ORDER BY release_time",
        conn, params={"currency": currency},
    )
    df["release_time"] = pd.to_datetime(df["release_time"]).dt.tz_localize(None)
    return df["release_time"]


def price_at_or_after(times_sorted, prices, query_times):
    idx = np.searchsorted(times_sorted, query_times, side="left")
    valid = idx < len(times_sorted)
    out = np.full(len(query_times), np.nan)
    out[valid] = prices[idx[valid]]
    return out


def abs_return_after(ohlcv, start_times, hours):
    times = ohlcv["time"].values
    closes = ohlcv["close"].values
    p0 = price_at_or_after(times, closes, start_times)
    p1 = price_at_or_after(times, closes, start_times + np.timedelta64(hours, "h"))
    with np.errstate(invalid="ignore", divide="ignore"):
        ret = np.abs((p1 - p0) / p0)
    return ret


def sample_random_baseline(ohlcv, event_times, n, rng):
    """Matched-random baseline, NOT a uniform-random draw across all hours.

    Real releases happen at fixed times of day (NFP always ~8:30am ET, ECB
    decisions always ~12:45pm CET, etc.) which coincide with active trading
    sessions. A uniform-random baseline across the full week would include
    quiet overnight/Asian-session hours with inherently smaller moves for
    reasons that have nothing to do with the release -- that would manufacture
    a fake "effect" out of ordinary session-liquidity patterns, not anything
    about the release itself. Caught before trusting the first run's result
    (see docs/phase-log.md) -- a real methodological bug, not a strictness
    tweak, same "bug vs strictness" standard as every other finding in this
    project.

    Fix: for each real event, shift it by a random whole number of weeks
    (2-52, either direction) -- this exactly preserves hour-of-day AND
    day-of-week, only varying which week, then reject candidates that land
    within 24h of ANY real event for this currency (any category)."""
    t_min, t_max = ohlcv["time"].min(), ohlcv["time"].max()
    event_times_arr = np.array(sorted(event_times))

    picks = []
    for et in event_times:
        placed = False
        for _attempt in range(100):
            weeks = int(rng.integers(2, 53)) * int(rng.choice([-1, 1]))
            candidate = et + np.timedelta64(weeks * 7, "D")
            if candidate < t_min or candidate > t_max - np.timedelta64(24, "h"):
                continue
            nearest_idx = np.searchsorted(event_times_arr, candidate)
            too_close = False
            for j in (nearest_idx - 1, nearest_idx):
                if 0 <= j < len(event_times_arr):
                    if abs((candidate - event_times_arr[j]) / np.timedelta64(1, "h")) < 24:
                        too_close = True
                        break
            if not too_close:
                picks.append(candidate)
                placed = True
                break
        if not placed:
            continue  # give up on this event's baseline match rather than force a bad one
    return np.array(picks, dtype="datetime64[ns]")


def main():
    env = load_env()
    db_url = (f"host=localhost port=5433 dbname=trading_platform "
              f"user=trading_app password={env.get('DB_PASSWORD')}")
    conn = psycopg.connect(db_url)
    rng = np.random.default_rng(RANDOM_SEED)

    currency_results = {}
    full_table = []

    for currency, pair in CURRENCY_PAIR_MAP.items():
        events = load_events(conn, currency)
        ohlcv = pd.read_pickle(DATASET_DIR / f"{pair}.pkl")[["time", "close"]].sort_values("time").reset_index(drop=True)

        event_times = events[(events >= ohlcv["time"].min()) & (events <= ohlcv["time"].max() - pd.Timedelta(hours=24))].values
        baseline_times = sample_random_baseline(ohlcv, event_times, len(event_times), rng)

        window_pass = {}
        for label, hours in WINDOWS_HOURS.items():
            event_ret = abs_return_after(ohlcv, event_times, hours)
            baseline_ret = abs_return_after(ohlcv, baseline_times, hours)
            event_ret = event_ret[~np.isnan(event_ret)]
            baseline_ret = baseline_ret[~np.isnan(baseline_ret)]

            mean_event = event_ret.mean()
            mean_baseline = baseline_ret.mean()
            ratio = mean_event / mean_baseline if mean_baseline > 0 else np.nan
            stat, pvalue = mannwhitneyu(event_ret, baseline_ret, alternative="greater")

            clears = (ratio >= EFFECT_SIZE_BAR) and (pvalue < PVALUE_BAR)
            window_pass[label] = clears

            full_table.append({
                "currency": currency, "pair": pair, "window": label,
                "n_events": len(event_ret), "n_baseline": len(baseline_ret),
                "mean_event_abs_ret": mean_event, "mean_baseline_abs_ret": mean_baseline,
                "ratio": ratio, "pvalue": pvalue, "clears_bar": clears,
            })

        currency_results[currency] = window_pass[PRIMARY_WINDOW]
        print(f"{currency} ({pair}): primary window {PRIMARY_WINDOW} "
              f"{'CLEARS' if window_pass[PRIMARY_WINDOW] else 'does not clear'} the bar "
              f"(1H={'clears' if window_pass['1H'] else 'no'}, "
              f"4H={'clears' if window_pass['4H'] else 'no'}, "
              f"24H={'clears' if window_pass['24H'] else 'no'})")

    conn.close()

    table = pd.DataFrame(full_table)
    print("\nFull table:")
    print(table.to_string(index=False))

    n_currencies_clearing = sum(currency_results.values())
    print(f"\nCurrencies clearing the primary ({PRIMARY_WINDOW}) bar: "
          f"{n_currencies_clearing} of {len(currency_results)}")
    verdict = "SIGNAL FOUND" if n_currencies_clearing >= 3 else "NO SIGNAL FOUND"
    print(f"Pre-declared bar (>=3 of 4 currencies clearing on {PRIMARY_WINDOW}): {verdict}")

    table.to_csv(DATASET_DIR / "h2_event_study_results.csv", index=False)


if __name__ == "__main__":
    main()
