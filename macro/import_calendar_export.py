"""
Imports CalendarExportEA.mq5's pipe-delimited output (real MT5 Calendar API
data, exported live -- see docs/phase-log.md Step 1) into the
`macro_calendar_events` table.

Usage: run after CalendarExportEA has produced its log file in the isolated
MT5 instance's MQL5\\Files\\CalendarExportEA\\ folder.
"""
import sys
from pathlib import Path

import psycopg

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
EXPORT_LOG = (Path("C:/Users/Administrator/AppData/Roaming/MetaQuotes/Terminal")
              / "85CCDB11961A17398C496650A57327FE" / "MQL5" / "Files"
              / "CalendarExportEA" / "calendar_export.log")

COLS = ["currency", "event_name", "category", "release_time", "actual_value",
        "previous_value", "importance"]


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


def main():
    if not EXPORT_LOG.exists():
        print(f"Export log not found at {EXPORT_LOG}", file=sys.stderr)
        sys.exit(1)

    env = load_env()
    db_url = (f"host=localhost port=5433 dbname=trading_platform "
              f"user=trading_app password={env.get('DB_PASSWORD')}")
    conn = psycopg.connect(db_url)

    # MT5's FILE_ANSI + FILE_CSV writer -- plain ANSI text, '|' delimited,
    # one row per FileWrite call (CRLF line endings).
    text = EXPORT_LOG.read_text(encoding="ansi", errors="replace")

    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) != len(COLS):
            print(f"SKIP malformed line ({len(parts)} fields): {line!r}")
            continue
        currency, event_name, category, release_time, actual_value, previous_value, importance = parts
        rows.append((
            currency, event_name, category, release_time,
            None if actual_value == "NULL" else float(actual_value),
            None if previous_value == "NULL" else float(previous_value),
            importance,
        ))

    if not rows:
        print("No rows parsed -- nothing to import.")
        return

    with conn.cursor() as cur:
        cur.executemany(
            """
            INSERT INTO macro_calendar_events
                (currency, event_name, event_category, release_time, actual_value, previous_value, importance)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (currency, event_name, release_time) DO UPDATE
                SET actual_value = EXCLUDED.actual_value,
                    previous_value = EXCLUDED.previous_value,
                    importance = EXCLUDED.importance,
                    fetched_at = now()
            """,
            rows,
        )
    conn.commit()
    conn.close()
    print(f"Imported {len(rows)} calendar event rows into macro_calendar_events.")


if __name__ == "__main__":
    main()
