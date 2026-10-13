from fastapi.testclient import TestClient


def test_liveness_reports_service_metadata(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "service": "orders-api",
        "version": "test",
        "environment": "test",
    }
    assert response.headers["X-Request-ID"]


def test_readiness_checks_database(client: TestClient) -> None:
    response = client.get("/health/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "checks": {"database": "ok"}}


def test_database_outage_fails_readiness_but_not_liveness(
    unavailable_db_client: TestClient,
) -> None:
    ready = unavailable_db_client.get("/health/ready")
    live = unavailable_db_client.get("/health")

    assert ready.status_code == 503
    assert ready.json() == {"status": "unavailable", "checks": {"database": "unavailable"}}
    # The ALB keeps routing to the task, so a DB blip does not become a full outage.
    assert live.status_code == 200
