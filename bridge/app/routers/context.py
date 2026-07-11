from datetime import datetime
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.db import get_connection

router = APIRouter()


class ContextIn(BaseModel):
    symbol: str
    snapshot_time: datetime
    d1_trend: Optional[str] = None
    h4_trend: Optional[str] = None
    atr_value: Optional[float] = None
    volatility_regime: Optional[str] = None
    session: Optional[str] = None
    spread: Optional[float] = None
    nearest_level_distance_atr: Optional[float] = None


@router.post("/log-context")
def log_context(ctx: ContextIn):
    # Upsert on (symbol, snapshot_time): a re-sent snapshot for the same bar
    # (e.g. EA restart) replaces rather than duplicates.
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO market_context (
                    symbol, snapshot_time, d1_trend, h4_trend, atr_value,
                    volatility_regime, session, spread, nearest_level_distance_atr
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (symbol, snapshot_time) DO UPDATE SET
                    d1_trend = EXCLUDED.d1_trend,
                    h4_trend = EXCLUDED.h4_trend,
                    atr_value = EXCLUDED.atr_value,
                    volatility_regime = EXCLUDED.volatility_regime,
                    session = EXCLUDED.session,
                    spread = EXCLUDED.spread,
                    nearest_level_distance_atr = EXCLUDED.nearest_level_distance_atr
                RETURNING id
                """,
                (
                    ctx.symbol, ctx.snapshot_time, ctx.d1_trend, ctx.h4_trend, ctx.atr_value,
                    ctx.volatility_regime, ctx.session, ctx.spread, ctx.nearest_level_distance_atr,
                ),
            )
            new_id = cur.fetchone()[0]
        conn.commit()
    return {"id": new_id}


_COLUMNS = (
    "id", "symbol", "snapshot_time", "d1_trend", "h4_trend", "atr_value",
    "volatility_regime", "session", "spread", "nearest_level_distance_atr", "created_at",
)


@router.get("/context/{symbol}/latest")
def get_latest_context(symbol: str):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"SELECT {', '.join(_COLUMNS)} FROM market_context "
                f"WHERE symbol = %s ORDER BY snapshot_time DESC LIMIT 1",
                (symbol.upper(),),
            )
            row = cur.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail=f"no context snapshot for {symbol}")
    return dict(zip(_COLUMNS, row))


@router.get("/context/{symbol}/history")
def get_context_history(symbol: str, limit: int = 50):
    limit = max(1, min(limit, 500))
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"SELECT {', '.join(_COLUMNS)} FROM market_context "
                f"WHERE symbol = %s ORDER BY snapshot_time DESC LIMIT %s",
                (symbol.upper(), limit),
            )
            rows = cur.fetchall()
    return [dict(zip(_COLUMNS, r)) for r in rows]
