from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_log_risk_state_insert_then_upsert():
    payload = {
        "trading_date": "2026-01-05",
        "scope": "test_scope",
        "starting_balance": 10000.0,
        "realized_pnl": -50.0,
        "loss_limit_hit": False,
        "trading_halted": False,
    }
    first = client.post("/log-risk-state", json=payload)
    assert first.status_code == 200
    first_id = first.json()["id"]

    payload["realized_pnl"] = -220.0
    payload["loss_limit_hit"] = True
    second = client.post("/log-risk-state", json=payload)
    assert second.status_code == 200
    assert second.json()["id"] == first_id
