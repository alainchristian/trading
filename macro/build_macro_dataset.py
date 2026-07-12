"""
Point-in-time join: FRED rate differentials + MT5 calendar events onto
existing H1 OHLCV, for the macro/rate-differential edge test (H1/H2, see
docs/phase-log.md). Committed script, not scratch -- addresses the
auditability gap noted in the task brief.

Point-in-time correctness (the most important property here, per the task
brief): a rate differential "as of" a given H1 bar must only reflect FRED
data whose vintage_date <= that bar's date. This is enforced with
pandas.merge_asof (backward direction, strict <=), not a plain date-equality
join that could silently pull in same-day-or-later data. See
macro/verify_pit.py for the underlying point-in-time verification of the
FRED values themselves.

Output: one row per (symbol, time) with rate-differential features, the
days-to-next-decision feature, and the H1 label (sign of next-24-H1-bar
forward return). Calendar-event columns are left absent/NaN if
macro_calendar_events hasn't been imported yet (see import_calendar_export.py) --
this script can be re-run once it has.
"""
import datetime as dt
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
OHLCV_ROOT = Path("C:/trading/_mt5-instance/mlfeature_results")
OHLCV_COLS = ["symbol", "time", "open", "high", "low", "close", "volume",
              "atr", "rsi_h1", "rsi_h4", "adx_h1", "spread"]

SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD"]
PAIR_CCY = {
    "EURUSD": ("EUR", "USD"),
    "GBPUSD": ("GBP", "USD"),
    "USDJPY": ("USD", "JPY"),
    "AUDUSD": ("AUD", "USD"),
}
N_LOOKAHEAD = 24  # bars -- same convention as every prior test in this repo


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


def load_ohlcv(symbol):
    path = OHLCV_ROOT / symbol / "dump.log"
    df = pd.read_csv(path, sep="|", names=OHLCV_COLS, encoding="utf-16")
    df["time"] = pd.to_datetime(df["time"], format="%Y.%m.%d %H:%M")
    df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
    return df


def load_macro_series(conn):
    df = pd.read_sql(
        "SELECT currency, series_type, obs_date, vintage_date, value FROM macro_series ORDER BY vintage_date",
        conn,
    )
    df["vintage_date"] = pd.to_datetime(df["vintage_date"])
    return df


def load_calendar_events(conn):
    try:
        df = pd.read_sql(
            "SELECT currency, event_category, release_time, actual_value, previous_value "
            "FROM macro_calendar_events ORDER BY release_time",
            conn,
        )
        df["release_time"] = pd.to_datetime(df["release_time"])
        return df
    except Exception as e:
        print(f"macro_calendar_events not available yet ({e}); "
              f"calendar-derived features will be NaN.")
        return pd.DataFrame(columns=["currency", "event_category", "release_time",
                                      "actual_value", "previous_value"])


def pit_series_for_currency(macro_df, currency, series_type):
    """A currency/series_type's point-in-time value series, sorted by
    vintage_date, ready for merge_asof against bar timestamps."""
    s = macro_df[(macro_df.currency == currency) & (macro_df.series_type == series_type)]
    s = s[["vintage_date", "value"]].sort_values("vintage_date").reset_index(drop=True)
    return s


def pit_asof(bar_times, series_df, value_col_name):
    """merge_asof: for each bar_time, the latest series_df row with
    vintage_date <= bar_time (strict point-in-time correctness -- never a
    later value). bar_times must be sorted."""
    left = pd.DataFrame({"time": pd.to_datetime(bar_times).astype("datetime64[ns]")})
    left = left.sort_values("time")
    right = series_df.rename(columns={"vintage_date": "time", "value": value_col_name}).copy()
    right["time"] = pd.to_datetime(right["time"]).astype("datetime64[ns]")
    merged = pd.merge_asof(left, right, on="time", direction="backward")
    merged = merged.drop_duplicates("time", keep="last").set_index("time")
    return merged[value_col_name].reindex(pd.to_datetime(bar_times).astype("datetime64[ns]")).values


def days_to_next_decision(bar_times, calendar_df, currency):
    """Forward-looking only -- scheduled decision dates are known in advance,
    no lookahead risk regardless of source (per the task brief's Step 3)."""
    events = calendar_df[(calendar_df.currency == currency) &
                          (calendar_df.event_category == "rate_decision")].sort_values("release_time")
    if events.empty:
        return np.full(len(bar_times), np.nan)
    event_times = events["release_time"].values
    out = np.full(len(bar_times), np.nan)
    idx = np.searchsorted(event_times, bar_times, side="right")
    valid = idx < len(event_times)
    out[valid] = (event_times[idx[valid]] - bar_times[valid]) / np.timedelta64(1, "D")
    return out


def build_symbol_dataset(symbol, macro_df, calendar_df):
    df = load_ohlcv(symbol)
    base_ccy, quote_ccy = PAIR_CCY[symbol]

    for series_type in ("short_rate", "yield_10y"):
        base_series = pit_series_for_currency(macro_df, base_ccy, series_type)
        quote_series = pit_series_for_currency(macro_df, quote_ccy, series_type)
        base_val = pit_asof(df["time"].values, base_series, "v")
        quote_val = pit_asof(df["time"].values, quote_series, "v")
        df[f"diff_{series_type}"] = base_val - quote_val

        # 1wk / 1mo rate of change of the differential level, computed from
        # the point-in-time value as of (bar_time - Nd) -- same merge_asof
        # method, so the lagged value is equally point-in-time correct.
        for label, days in (("1wk", 7), ("1mo", 30)):
            lag_times = df["time"].values - np.timedelta64(days, "D")
            base_lag = pit_asof(lag_times, base_series, "v")
            quote_lag = pit_asof(lag_times, quote_series, "v")
            df[f"diff_{series_type}_roc_{label}"] = df[f"diff_{series_type}"] - (base_lag - quote_lag)

    df["days_to_next_decision_base"] = days_to_next_decision(df["time"].values, calendar_df, base_ccy)
    df["days_to_next_decision_quote"] = days_to_next_decision(df["time"].values, calendar_df, quote_ccy)

    # H1 label: sign of the next-N_LOOKAHEAD-bar forward return. Same
    # lookahead convention as every prior test in this repo (docs/phase-log.md).
    fwd_close = df["close"].shift(-N_LOOKAHEAD)
    df["fwd_return"] = (fwd_close - df["close"]) / df["close"]
    df["label_up"] = (df["fwd_return"] > 0).astype("Int64")
    df.loc[df["fwd_return"].isna(), "label_up"] = pd.NA

    return df


def main():
    env = load_env()
    db_url = (f"host=localhost port=5433 dbname=trading_platform "
              f"user=trading_app password={env.get('DB_PASSWORD')}")
    conn = psycopg.connect(db_url)

    macro_df = load_macro_series(conn)
    calendar_df = load_calendar_events(conn)
    conn.close()

    out_dir = Path("C:/trading/_mt5-instance/macro_dataset")
    out_dir.mkdir(exist_ok=True)

    all_frames = []
    for symbol in SYMBOLS:
        df = build_symbol_dataset(symbol, macro_df, calendar_df)
        df.to_pickle(out_dir / f"{symbol}.pkl")
        all_frames.append(df)
        n_valid_label = df["label_up"].notna().sum()
        print(f"{symbol}: {len(df)} rows, {n_valid_label} with a valid label, "
              f"diff_short_rate range [{df['diff_short_rate'].min():.3f}, {df['diff_short_rate'].max():.3f}]")

    pd.concat(all_frames, ignore_index=True).to_pickle(out_dir / "pooled.pkl")
    print(f"\nSaved per-symbol + pooled datasets to {out_dir}")


if __name__ == "__main__":
    main()
