import json
from datetime import datetime
from typing import Optional

from fastapi import APIRouter
from pydantic import BaseModel

from app.db import get_connection

router = APIRouter()


class SignalIn(BaseModel):
    strategy_variant: str = "phase1_confluence"
    symbol: str
    signal_time: datetime
    direction: str
    d1_trend: Optional[str] = None
    h4_setup_valid: Optional[bool] = None
    h1_entry_trigger: Optional[str] = None
    atr_value: Optional[float] = None
    proposed_entry: Optional[float] = None
    proposed_sl: Optional[float] = None
    proposed_tp1: Optional[float] = None
    proposed_tp2: Optional[float] = None
    risk_percent: Optional[float] = None
    lot_size: Optional[float] = None
    spread_at_signal: Optional[float] = None
    session: Optional[str] = None
    taken: bool
    rejection_reason: Optional[str] = None
    features: Optional[dict] = None


@router.post("/log-signal")
def log_signal(signal: SignalIn):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO signals (
                    strategy_variant, symbol, signal_time, direction, d1_trend, h4_setup_valid,
                    h1_entry_trigger, atr_value, proposed_entry, proposed_sl,
                    proposed_tp1, proposed_tp2, risk_percent, lot_size,
                    spread_at_signal, session, taken, rejection_reason, features
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
                RETURNING id
                """,
                (
                    signal.strategy_variant,
                    signal.symbol,
                    signal.signal_time,
                    signal.direction,
                    signal.d1_trend,
                    signal.h4_setup_valid,
                    signal.h1_entry_trigger,
                    signal.atr_value,
                    signal.proposed_entry,
                    signal.proposed_sl,
                    signal.proposed_tp1,
                    signal.proposed_tp2,
                    signal.risk_percent,
                    signal.lot_size,
                    signal.spread_at_signal,
                    signal.session,
                    signal.taken,
                    signal.rejection_reason,
                    json.dumps(signal.features) if signal.features is not None else None,
                ),
            )
            new_id = cur.fetchone()[0]
        conn.commit()
    return {"id": new_id}
