import math
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter()

# Real broker specs, verified via SymbolInfoDumpEA.mq5 (Phase 1 closeout +
# decision-support pivot) -- not reimplemented/guessed. USDJPY's tick_value
# is rate-dependent (JPY profit converted to USD) and has no fixed constant;
# it's derived per-request from contract_size * tick_size / entry_price,
# the same method already verified in the Phase 1 closeout's own position-
# sizing spot-check.
SYMBOL_SPECS = {
    "EURUSD": {"tick_size": 0.00001, "tick_value": 1.0, "lot_step": 0.01, "lot_min": 0.01, "lot_max": 500.0, "contract": 100000.0},
    "GBPUSD": {"tick_size": 0.00001, "tick_value": 1.0, "lot_step": 0.01, "lot_min": 0.01, "lot_max": 500.0, "contract": 100000.0},
    "AUDUSD": {"tick_size": 0.00001, "tick_value": 1.0, "lot_step": 0.01, "lot_min": 0.01, "lot_max": 500.0, "contract": 100000.0},
    "USDJPY": {"tick_size": 0.001, "tick_value": None, "lot_step": 0.01, "lot_min": 0.01, "lot_max": 500.0, "contract": 100000.0},
    "GOLD": {"tick_size": 0.01, "tick_value": 0.01, "lot_step": 1.0, "lot_min": 1.0, "lot_max": 1000000.0, "contract": 1.0},
    "US500": {"tick_size": 0.01, "tick_value": 0.01, "lot_step": 0.1, "lot_min": 0.1, "lot_max": 250.0, "contract": 1.0},
}


class RiskCalcIn(BaseModel):
    symbol: str
    balance: float
    risk_percent: float
    entry_price: float
    stop_loss_price: float


class RiskCalcOut(BaseModel):
    lot_size: float
    sl_distance_price: float
    risk_money: float
    risk_percent_actual: float


@router.post("/risk/calculate", response_model=RiskCalcOut)
def calculate_lot_size(req: RiskCalcIn):
    """Ports RiskManager::CalculateLotSize (MQL5) exactly -- same formula,
    same floor-only rounding, same never-round-up guarantee, verified
    correct against real trade data in the Phase 1 closeout. Not
    reimplemented from scratch on purpose."""
    spec = SYMBOL_SPECS.get(req.symbol.upper())
    if spec is None:
        raise HTTPException(status_code=400, detail=f"unknown symbol {req.symbol}; known: {sorted(SYMBOL_SPECS)}")

    sl_distance = abs(req.entry_price - req.stop_loss_price)
    if sl_distance <= 0:
        raise HTTPException(status_code=400, detail="invalid_sl_distance")

    tick_value = spec["tick_value"]
    if tick_value is None:  # USDJPY: rate-dependent, derived from this request's own entry price
        if req.entry_price <= 0:
            raise HTTPException(status_code=400, detail="invalid_entry_price")
        tick_value = spec["contract"] * spec["tick_size"] / req.entry_price

    risk_money = req.balance * (req.risk_percent / 100.0)
    loss_per_lot = (sl_distance / spec["tick_size"]) * tick_value
    if loss_per_lot <= 0:
        raise HTTPException(status_code=400, detail="invalid_loss_per_lot")

    raw_lots = risk_money / loss_per_lot
    rounded = math.floor(raw_lots / spec["lot_step"]) * spec["lot_step"]
    rounded = round(rounded, 4)

    if rounded < spec["lot_min"]:
        raise HTTPException(status_code=400, detail="lot_size_below_minimum")
    if rounded > spec["lot_max"]:
        rounded = spec["lot_max"]  # clipping down only ever reduces realized risk

    realized_risk_money = rounded * loss_per_lot
    realized_risk_pct = 100.0 * realized_risk_money / req.balance if req.balance > 0 else 0.0

    return RiskCalcOut(
        lot_size=rounded,
        sl_distance_price=sl_distance,
        risk_money=round(realized_risk_money, 2),
        risk_percent_actual=round(realized_risk_pct, 4),
    )
