from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_log_event_with_payload():
    response = client.post(
        "/log-event",
        json={
            "source": "ea",
            "event_type": "partial_close",
            "payload": {"ticket": 123456789, "fraction": 0.3, "r_multiple": 1.0},
        },
    )
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_log_event_without_payload():
    response = client.post("/log-event", json={"source": "ea", "event_type": "startup"})
    assert response.status_code == 200
