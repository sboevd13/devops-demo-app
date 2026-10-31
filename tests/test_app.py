from fastapi.testclient import TestClient

from app.main import app


def test_health():
    with TestClient(app) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_user_can_be_saved_and_listed():
    test_name = "CI Test User"

    with TestClient(app) as client:
        response = client.post(
            "/users",
            data={"name": test_name},
            follow_redirects=False,
        )

        assert response.status_code == 303

        response = client.get("/users")

        assert response.status_code == 200
        assert test_name in response.text


def test_metrics_endpoint():
    with TestClient(app) as client:
        client.get("/health")
        response = client.get("/metrics")

    assert response.status_code == 200
    assert "http_requests_total" in response.text
