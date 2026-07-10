from datetime import date

from fastapi import APIRouter
from pydantic import BaseModel

from app.db import get_connection

router = APIRouter()


class RiskStateIn(BaseModel):
    trading_date: date
    scope: str = "account"
    starting_balance: float
    realized_pnl: float = 0.0
    loss_limit_hit: bool = False
    trading_halted: bool = False


@router.post("/log-risk-state")
def log_risk_state(state: RiskStateIn):
    # Upsert: the EA computes daily/weekly loss-limit decisions locally from
    # MT5's own trade history (never blocking on the bridge), and calls this
    # purely to keep a Postgres record for later dashboard/analysis use.
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO risk_state (
                    trading_date, scope, starting_balance, realized_pnl,
                    loss_limit_hit, trading_halted
                ) VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (trading_date, scope) DO UPDATE SET
                    realized_pnl = EXCLUDED.realized_pnl,
                    loss_limit_hit = EXCLUDED.loss_limit_hit,
                    trading_halted = EXCLUDED.trading_halted,
                    updated_at = now()
                RETURNING id
                """,
                (
                    state.trading_date,
                    state.scope,
                    state.starting_balance,
                    state.realized_pnl,
                    state.loss_limit_hit,
                    state.trading_halted,
                ),
            )
            new_id = cur.fetchone()[0]
        conn.commit()
    return {"id": new_id}
