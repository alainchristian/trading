import json
from contextlib import contextmanager

import psycopg

from app.config import settings


@contextmanager
def get_connection():
    conn = psycopg.connect(settings.dsn)
    try:
        yield conn
    finally:
        conn.close()


def log_event(source: str, event_type: str, payload: dict | None = None) -> None:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO system_events (source, event_type, payload) VALUES (%s, %s, %s)",
                (source, event_type, json.dumps(payload) if payload is not None else None),
            )
        conn.commit()
