from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_log_signal_taken():
    response = client.post(
        "/log-signal",
        json={
            "symbol": "EURUSD",
            "signal_time": "2026-01-05T10:00:00Z",
            "direction": "buy",
            "d1_trend": "bullish",
            "h4_setup_valid": True,
            "h1_entry_trigger": "bullish_engulfing",
            "atr_value": 0.00085,
            "proposed_entry": 1.0950,
            "proposed_sl": 1.0930,
            "proposed_tp1": 1.0970,
            "proposed_tp2": 1.0990,
            "risk_percent": 1.0,
            "lot_size": 0.5,
            "spread_at_signal": 1.2,
            "session": "london",
            "taken": True,
            "rejection_reason": None,
            "features": {"rsi_h1": 38.2, "adx_d1": 27.5},
        },
    )
    assert response.status_code == 200
    assert isinstance(response.json()["id"], int)


def test_log_signal_rejected_minimal_fields():
    response = client.post(
        "/log-signal",
        json={
            "symbol": "EURUSD",
            "signal_time": "2026-01-05T11:00:00Z",
            "direction": "sell",
            "taken": False,
            "rejection_reason": "d1_trend_not_directional",
        },
    )
    assert response.status_code == 200
    assert isinstance(response.json()["id"], int)
