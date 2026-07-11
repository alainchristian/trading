from datetime import datetime
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.db import get_connection

router = APIRouter()

# Columns PATCH is allowed to touch, in the order they may appear in the SET
# clause. Fixed by this whitelist (never built from arbitrary user input), so
# building the SET clause from these names is safe.
_UPDATABLE_COLUMNS = (
    "close_time",
    "close_price",
    "r_multiple",
    "mfe",
    "mae",
    "exit_reason",
    "profit",
)


class TradeOpenIn(BaseModel):
    strategy_variant: str = "phase1_confluence"
    signal_id: Optional[int] = None
    ticket: int
    symbol: str
    direction: str
    open_time: datetime
    open_price: float
    initial_sl: float
    initial_tp1: Optional[float] = None
    initial_tp2: Optional[float] = None
    lot_size: float


class TradeUpdateIn(BaseModel):
    close_time: Optional[datetime] = None
    close_price: Optional[float] = None
    r_multiple: Optional[float] = None
    mfe: Optional[float] = None
    mae: Optional[float] = None
    exit_reason: Optional[str] = None
    profit: Optional[float] = None


@router.post("/log-trade")
def log_trade(trade: TradeOpenIn):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO trades (
                    strategy_variant, signal_id, ticket, symbol, direction, open_time, open_price,
                    initial_sl, initial_tp1, initial_tp2, lot_size
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                (
                    trade.strategy_variant,
                    trade.signal_id,
                    trade.ticket,
                    trade.symbol,
                    trade.direction,
                    trade.open_time,
                    trade.open_price,
                    trade.initial_sl,
                    trade.initial_tp1,
                    trade.initial_tp2,
                    trade.lot_size,
                ),
            )
            new_id = cur.fetchone()[0]
        conn.commit()
    return {"id": new_id}


@router.patch("/log-trade/{ticket}")
def update_trade(ticket: int, update: TradeUpdateIn):
    fields = update.model_dump(exclude_unset=True)
    fields = {k: v for k, v in fields.items() if k in _UPDATABLE_COLUMNS}
    if not fields:
        raise HTTPException(status_code=400, detail="no updatable fields provided")

    set_clause = ", ".join(f"{col} = %s" for col in fields)
    values = list(fields.values()) + [ticket]

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"UPDATE trades SET {set_clause}, updated_at = now() "
                f"WHERE ticket = %s RETURNING id",
                values,
            )
            row = cur.fetchone()
        conn.commit()

    if row is None:
        raise HTTPException(status_code=404, detail=f"no trade with ticket {ticket}")
    return {"id": row[0]}


@router.get("/trades/{ticket}")
def get_trade(ticket: int):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, strategy_variant, signal_id, ticket, symbol, direction, open_time, close_time,
                       open_price, close_price, initial_sl, initial_tp1, initial_tp2,
                       lot_size, r_multiple, mfe, mae, exit_reason, profit
                FROM trades WHERE ticket = %s
                """,
                (ticket,),
            )
            row = cur.fetchone()
            columns = [desc[0] for desc in cur.description] if cur.description else []

    if row is None:
        raise HTTPException(status_code=404, detail=f"no trade with ticket {ticket}")
    return dict(zip(columns, row))
