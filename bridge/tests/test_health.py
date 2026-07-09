from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_ping_db():
    response = client.get("/ping-db")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
