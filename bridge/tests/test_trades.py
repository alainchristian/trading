import random

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def _random_ticket() -> int:
    # Real inserts against the dev DB (same pattern as test_health.py) with a
    # UNIQUE(ticket) constraint, so pick a fresh ticket per test run.
    return random.randint(10**9, 2 * 10**9)


def test_log_trade_open_and_get():
    ticket = _random_ticket()

    open_response = client.post(
        "/log-trade",
        json={
            "ticket": ticket,
            "symbol": "EURUSD",
            "direction": "buy",
            "open_time": "2026-01-05T10:00:05Z",
            "open_price": 1.0951,
            "initial_sl": 1.0930,
            "initial_tp1": 1.0970,
            "initial_tp2": 1.0990,
            "lot_size": 0.5,
        },
    )
    assert open_response.status_code == 200
    assert isinstance(open_response.json()["id"], int)

    get_response = client.get(f"/trades/{ticket}")
    assert get_response.status_code == 200
    body = get_response.json()
    assert body["ticket"] == ticket
    assert body["close_time"] is None
    assert body["r_multiple"] is None


def test_patch_trade_partial_then_full_close():
    ticket = _random_ticket()
    client.post(
        "/log-trade",
        json={
            "ticket": ticket,
            "symbol": "EURUSD",
            "direction": "sell",
            "open_time": "2026-01-05T12:00:00Z",
            "open_price": 1.1000,
            "initial_sl": 1.1020,
            "lot_size": 0.3,
        },
    )

    partial_response = client.patch(f"/log-trade/{ticket}", json={"mfe": 0.0010, "mae": 0.0002})
    assert partial_response.status_code == 200

    close_response = client.patch(
        f"/log-trade/{ticket}",
        json={
            "close_time": "2026-01-05T15:00:00Z",
            "close_price": 1.0960,
            "r_multiple": 2.0,
            "mfe": 0.0042,
            "mae": 0.0003,
            "exit_reason": "tp2",
            "profit": 120.0,
        },
    )
    assert close_response.status_code == 200

    get_response = client.get(f"/trades/{ticket}")
    body = get_response.json()
    assert body["exit_reason"] == "tp2"
    assert body["r_multiple"] == 2.0


def test_patch_trade_unknown_ticket_404():
    response = client.patch("/log-trade/999999999999", json={"exit_reason": "sl_hit"})
    assert response.status_code == 404


def test_get_trade_unknown_ticket_404():
    response = client.get("/trades/999999999999")
    assert response.status_code == 404


def test_patch_trade_no_fields_400():
    ticket = _random_ticket()
    client.post(
        "/log-trade",
        json={
            "ticket": ticket,
            "symbol": "EURUSD",
            "direction": "buy",
            "open_time": "2026-01-05T09:00:00Z",
            "open_price": 1.0900,
            "initial_sl": 1.0880,
            "lot_size": 0.1,
        },
    )
    response = client.patch(f"/log-trade/{ticket}", json={})
    assert response.status_code == 400
