from datetime import datetime, timezone

import psycopg
from fastapi import APIRouter, HTTPException

from app.db import get_connection, log_event

router = APIRouter()


@router.get("/health")
def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}


@router.get("/ping-db")
def ping_db():
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        log_event("bridge", "heartbeat", {"timestamp": datetime.now(timezone.utc).isoformat()})
    except psycopg.Error as exc:
        raise HTTPException(status_code=503, detail=f"database unreachable: {exc}") from exc

    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}
