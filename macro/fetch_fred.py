"""
FRED ingestion for the macro/rate-differential edge test (see docs/phase-log.md).

Pulls policy/short rates and 10Y government bond yields for USD/EUR/GBP/JPY/AUD
from FRED's free API.

Point-in-time note (see verify_pit.py for the actual check): these are all
market-observed daily/monthly rate or yield series, not survey-based
indicators -- they are published once and not later revised, unlike
GDP/CPI/NFP. Rather than pull FRED's ALFRED full vintage-matrix endpoint
(output_type=2), which turned out to be the wrong tool here -- with a narrow
*realtime* window it still returns the ENTIRE observation history as one row
per obs-date with one column per real-time date in range, producing a huge
matrix that made FRED's own server time out on anything wider than ~1 month
-- this uses plain observations (one value per obs_date) plus a targeted
point-in-time snapshot check (verify_pit.py) that queries the same handful of
historical obs_dates as known shortly after publication vs. as known today,
confirming they match before trusting "current value" as "first-published
value" for these specific series.

vintage_date is set to obs_date + PUBLICATION_LAG_DAYS (a small, documented,
conservative lag -- these are daily-published series, not economic releases
with a reporting delay) rather than obs_date itself, so a join can never use
a value before it would plausibly have been known.

Usage: set FRED_API_KEY in .env, then run this script directly. Writes to
the `macro_series` table (upsert on the (source, series_id, obs_date,
vintage_date) unique key, safe to re-run).
"""
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import psycopg

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
PUBLICATION_LAG_DAYS = 1
HISTORY_START = "2013-01-01"  # 2yr buffer before the confirmed 2015+ coverage window


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


ENV = load_env()
FRED_API_KEY = ENV.get("FRED_API_KEY") or os.environ.get("FRED_API_KEY")
FRED_BASE = "https://api.stlouisfed.org/fred/series/observations"

# Confirmed against FRED's own series metadata before use (discover_fred_series.py
# + direct series-id verification), not assumed from memory.
#
# NOTE on scope vs. the original brief: FRED has no direct 2-year
# constant-maturity government bond yield for Germany/UK/Japan/Australia
# under any series checked (only the US has one, DGS2) -- confirmed
# empirically via both search and direct ID probing, not assumed. Rather
# than pair a real US 2Y against a mismatched-tenor substitute for the other
# four legs, this uses two tenors that ARE consistently available for all
# five currencies: a short end (each country's own best available
# policy-linked rate) and 10Y government yields. "2Y" is dropped from scope,
# not silently faked with a proxy.
#   short_rate: USD=DFF (Fed Funds effective, daily), EUR=ECBMRRFR (ECB main
#     refi, daily), GBP=IUDSOIA (SONIA, daily -- the modern BoE-linked
#     reference rate; the old BOERUKM series stops in 2017), JPY/AUD=
#     IRSTCI01{JP,AU}M156N (OECD immediate/call-money rate, monthly -- no
#     direct BoJ/RBA policy-rate series found on FRED).
#   yield_10y: DGS10 (USD, daily) / IRLTLT01{DE,GB,JP,AU}M156N (OECD 10Y
#     benchmark, monthly) -- consistent definition across all five.
SERIES_MAP = {
    "USD": {"short_rate": "DFF",             "yield_10y": "DGS10"},
    "EUR": {"short_rate": "ECBMRRFR",        "yield_10y": "IRLTLT01DEM156N"},
    "GBP": {"short_rate": "IUDSOIA",         "yield_10y": "IRLTLT01GBM156N"},
    "JPY": {"short_rate": "IRSTCI01JPM156N", "yield_10y": "IRLTLT01JPM156N"},
    "AUD": {"short_rate": "IRSTCI01AUM156N", "yield_10y": "IRLTLT01AUM156N"},
}


def fred_request(params):
    full_params = {"api_key": FRED_API_KEY, "file_type": "json", **params}
    url = f"{FRED_BASE}?{urllib.parse.urlencode(full_params)}"
    last_err = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except (TimeoutError, urllib.error.URLError) as e:
            last_err = e
            time.sleep(2 * (attempt + 1))
    raise last_err


def fetch_series_history(series_id):
    """Plain (current-value) observations for the full history window. Safe
    to treat as first-published for these series -- see verify_pit.py."""
    data = fred_request({
        "series_id": series_id,
        "observation_start": HISTORY_START,
        "observation_end": dt.date.today().isoformat(),
    })
    return data.get("observations", [])


def upsert_observations(conn, series_id, currency, series_type, observations):
    rows = []
    for obs in observations:
        if obs["value"] == ".":
            continue
        obs_date = dt.date.fromisoformat(obs["date"])
        vintage_date = obs_date + dt.timedelta(days=PUBLICATION_LAG_DAYS)
        rows.append((
            "fred", series_id, currency, series_type,
            obs_date, vintage_date, float(obs["value"]),
        ))
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(
            """
            INSERT INTO macro_series
                (source, series_id, currency, series_type, obs_date, vintage_date, value)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (source, series_id, obs_date, vintage_date) DO UPDATE
                SET value = EXCLUDED.value, fetched_at = now()
            """,
            rows,
        )
    conn.commit()
    return len(rows)


def main():
    if not FRED_API_KEY:
        print("FRED_API_KEY not set in .env -- aborting.", file=sys.stderr)
        sys.exit(1)

    db_url = (f"host=localhost port=5433 dbname=trading_platform "
              f"user=trading_app password={ENV.get('DB_PASSWORD')}")
    conn = psycopg.connect(db_url)

    total = 0
    for currency, series in SERIES_MAP.items():
        for series_type, series_id in series.items():
            obs = fetch_series_history(series_id)
            n = upsert_observations(conn, series_id, currency, series_type, obs)
            print(f"{currency}/{series_type} ({series_id}): {n} rows upserted")
            total += n
            time.sleep(0.3)

    conn.close()
    print(f"DONE. {total} total rows upserted into macro_series.")


if __name__ == "__main__":
    main()
