"""
One-time helper: confirm real FRED series IDs for each currency's policy
rate and 2Y/10Y government bond yield, rather than guessing ticker symbols
from memory (non-US series IDs in particular are not obvious/well-known).
Prints candidates with title + observation start/end so a human can pick the
right one; results get hand-copied into fetch_fred.py's SERIES_MAP once
confirmed. Not meant to run repeatedly or be imported.
"""
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"


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
FRED_API_KEY = ENV.get("FRED_API_KEY")
SEARCH_URL = "https://api.stlouisfed.org/fred/series/search"

QUERIES = {
    ("USD", "policy_rate"): "federal funds effective rate",
    ("USD", "yield_2y"): "2-year treasury constant maturity",
    ("USD", "yield_10y"): "10-year treasury constant maturity",
    ("EUR", "policy_rate"): "ECB main refinancing rate",
    ("EUR", "yield_2y"): "germany 2-year government bond yield",
    ("EUR", "yield_10y"): "germany 10-year government bond yield",
    ("GBP", "policy_rate"): "bank of england official bank rate",
    ("GBP", "yield_2y"): "united kingdom 2-year government bond yield",
    ("GBP", "yield_10y"): "united kingdom 10-year government bond yield",
    ("JPY", "policy_rate"): "japan policy rate discount",
    ("JPY", "yield_2y"): "japan 2-year government bond yield",
    ("JPY", "yield_10y"): "japan 10-year government bond yield",
    ("AUD", "policy_rate"): "australia cash rate reserve bank",
    ("AUD", "yield_2y"): "australia 2-year government bond yield",
    ("AUD", "yield_10y"): "australia 10-year government bond yield",
}


def search(query):
    params = {"search_text": query, "api_key": FRED_API_KEY, "file_type": "json", "limit": 5}
    url = f"{SEARCH_URL}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.loads(resp.read().decode())


def main():
    if not FRED_API_KEY:
        print("FRED_API_KEY not set in .env", file=sys.stderr)
        sys.exit(1)

    for (currency, series_type), query in QUERIES.items():
        print(f"\n=== {currency} / {series_type} :: \"{query}\" ===")
        try:
            data = search(query)
        except Exception as e:
            print(f"  ERROR: {e}")
            continue
        for s in data.get("seriess", [])[:5]:
            print(f"  {s['id']:20s} freq={s.get('frequency_short','?'):3s} "
                  f"{s.get('observation_start')} -> {s.get('observation_end')}  {s['title']}")


if __name__ == "__main__":
    main()
