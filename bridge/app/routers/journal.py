from datetime import datetime
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.db import get_connection

router = APIRouter()


class JournalOpenIn(BaseModel):
    symbol: str
    direction: str
    open_time: datetime
    open_price: float
    stop_loss: float
    take_profit: Optional[float] = None
    lot_size: float
    rationale: Optional[str] = None
    context_snapshot_id: Optional[int] = None


class JournalCloseIn(BaseModel):
    close_time: datetime
    close_price: float
    outcome_notes: Optional[str] = None


_COLUMNS = (
    "id", "symbol", "direction", "open_time", "close_time", "open_price", "close_price",
    "stop_loss", "take_profit", "lot_size", "r_multiple", "rationale",
    "context_snapshot_id", "outcome_notes", "created_at", "updated_at",
)


@router.post("/journal/trades")
def open_journal_trade(trade: JournalOpenIn):
    if trade.direction not in ("buy", "sell"):
        raise HTTPException(status_code=400, detail="direction must be 'buy' or 'sell'")
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO journal_trades (
                    symbol, direction, open_time, open_price, stop_loss,
                    take_profit, lot_size, rationale, context_snapshot_id
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                (
                    trade.symbol, trade.direction, trade.open_time, trade.open_price, trade.stop_loss,
                    trade.take_profit, trade.lot_size, trade.rationale, trade.context_snapshot_id,
                ),
            )
            new_id = cur.fetchone()[0]
        conn.commit()
    return {"id": new_id}


@router.patch("/journal/trades/{trade_id}")
def close_journal_trade(trade_id: int, close: JournalCloseIn):
    # r_multiple is computed here, server-side, from the ORIGINAL stop_loss
    # stored at open time -- never a since-moved stop -- so it stays
    # comparable to how the automated system's own R-multiples are computed
    # (see ExitManager.mqh / addendum 2). Not trusted to client input.
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT direction, open_price, stop_loss FROM journal_trades WHERE id = %s",
                (trade_id,),
            )
            row = cur.fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail=f"no journal trade with id {trade_id}")
            direction, open_price, stop_loss = row

            r_distance = abs(open_price - stop_loss)
            r_multiple = None
            if r_distance > 0:
                realized_move = (close.close_price - open_price) if direction == "buy" else (open_price - close.close_price)
                r_multiple = realized_move / r_distance

            cur.execute(
                """
                UPDATE journal_trades SET
                    close_time = %s, close_price = %s, r_multiple = %s,
                    outcome_notes = %s, updated_at = now()
                WHERE id = %s
                RETURNING id
                """,
                (close.close_time, close.close_price, r_multiple, close.outcome_notes, trade_id),
            )
            updated = cur.fetchone()
        conn.commit()
    return {"id": updated[0], "r_multiple": r_multiple}


@router.get("/journal/trades")
def list_journal_trades(symbol: Optional[str] = None, limit: int = 50):
    limit = max(1, min(limit, 500))
    query = f"SELECT {', '.join(_COLUMNS)} FROM journal_trades"
    params = []
    if symbol:
        query += " WHERE symbol = %s"
        params.append(symbol.upper())
    query += " ORDER BY open_time DESC LIMIT %s"
    params.append(limit)

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            rows = cur.fetchall()
    return [dict(zip(_COLUMNS, r)) for r in rows]


@router.get("/journal/summary")
def journal_summary(symbol: Optional[str] = None):
    # Honest, descriptive-only: win rate / avg R / total trades from CLOSED
    # trades, R relative to the initial SL distance -- the same convention
    # used throughout this project's own analysis. No projection, no
    # prediction of future performance.
    query = "SELECT r_multiple FROM journal_trades WHERE close_time IS NOT NULL AND r_multiple IS NOT NULL"
    params = []
    if symbol:
        query += " AND symbol = %s"
        params.append(symbol.upper())

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            r_multiples = [row[0] for row in cur.fetchall()]

    n = len(r_multiples)
    if n == 0:
        return {"total_closed_trades": 0, "win_rate_pct": None, "avg_r_multiple": None}

    wins = sum(1 for r in r_multiples if r > 0)
    return {
        "total_closed_trades": n,
        "win_rate_pct": round(100.0 * wins / n, 2),
        "avg_r_multiple": round(sum(r_multiples) / n, 4),
    }
