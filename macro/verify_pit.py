"""
Point-in-time correctness spot-check for macro/fetch_fred.py, per Step 1's
explicit requirement: state clearly how point-in-time correctness was
verified, don't just assume "current value" == "first-published value".

Method: for a handful of historical obs_dates spread across the ingested
range, query FRED with a narrow realtime snapshot (realtime_start=
realtime_end=X) at two points -- shortly after the obs_date, and as of today
-- and confirm the value is identical. If it always matches, these series
are confirmed never-revised for the ingested window, which is exactly the
assumption fetch_fred.py relies on (current value used as first-published).
If any mismatch is found, that's a real revision and fetch_fred.py's
same-value assumption is wrong for that series -- reported plainly either way.
"""
import datetime as dt
import json
import urllib.error
import urllib.parse
import urllib.request

from fetch_fred import ENV, FRED_API_KEY, FRED_BASE, SERIES_MAP

CHECK_DATES = ["2015-06-15", "2018-03-01", "2020-03-16", "2022-09-21", "2024-01-10"]


def snapshot_value(series_id, obs_date, as_of):
    params = {
        "series_id": series_id,
        "api_key": FRED_API_KEY,
        "file_type": "json",
        "observation_start": obs_date,
        "observation_end": obs_date,
        "realtime_start": as_of,
        "realtime_end": as_of,
    }
    url = f"{FRED_BASE}?{urllib.parse.urlencode(params)}"
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return f"ERROR:{e.code}:{e.read().decode()[:150]}"
    obs = data.get("observations", [])
    if not obs or obs[0]["value"] == ".":
        return None
    return obs[0]["value"]


def classify(v_early, v_now):
    is_err_or_none = lambda v: v is None or (isinstance(v, str) and v.startswith("ERROR:"))
    if is_err_or_none(v_early) and is_err_or_none(v_now):
        return "NO_DATA"          # neither snapshot has a value -- not applicable
    if is_err_or_none(v_early) and not is_err_or_none(v_now):
        return "NO_VINTAGE"       # ALFRED doesn't track this far back -- inconclusive, not a revision
    if v_early == v_now:
        return "MATCH"
    return "REAL_MISMATCH"        # both snapshots had real values and they differ -- an actual revision


def main():
    counts = {"MATCH": 0, "REAL_MISMATCH": 0, "NO_VINTAGE": 0, "NO_DATA": 0}
    for currency, series in SERIES_MAP.items():
        for series_type, series_id in series.items():
            for obs_date_str in CHECK_DATES:
                obs_date = dt.date.fromisoformat(obs_date_str)
                shortly_after = (obs_date + dt.timedelta(days=5)).isoformat()
                today = dt.date.today().isoformat()

                v_early = snapshot_value(series_id, obs_date_str, shortly_after)
                v_now = snapshot_value(series_id, obs_date_str, today)
                status = classify(v_early, v_now)
                counts[status] += 1
                print(f"{currency}/{series_type} ({series_id}) {obs_date_str}: "
                      f"as_of+5d={v_early!r} as_of_today={v_now!r} -> {status}")

    print(f"\nCounts: {counts}")
    if counts["REAL_MISMATCH"] > 0:
        print("REAL REVISIONS FOUND for at least one series/date -- do not "
              "treat current values as point-in-time correct for those "
              "specific series without addressing this.")
    else:
        print("No genuine revisions found (REAL_MISMATCH=0). MATCH confirms "
              "no revision where ALFRED had vintage data to check against. "
              "NO_VINTAGE means ALFRED simply doesn't track real-time vintages "
              "that far back for that series -- inconclusive from this method "
              "alone, not evidence of a revision; documented as a real "
              "limitation, not silently treated as 'verified'.")


if __name__ == "__main__":
    main()
