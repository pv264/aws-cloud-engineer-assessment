from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from orders_api import service
from orders_api.models import Order
from tests.conftest import make_settings


def _order_count(app: FastAPI) -> int:
    with app.state.session_factory() as session:
        return session.scalar(select(func.count()).select_from(Order))


def test_retry_with_same_key_returns_original_order(
    app: FastAPI, client: TestClient, order_payload: dict[str, object]
) -> None:
    headers = {"Idempotency-Key": "checkout-7f3a"}

    first = client.post("/orders", json=order_payload, headers=headers)
    retry = client.post("/orders", json=order_payload, headers=headers)

    assert first.status_code == 201
    assert retry.status_code == 200
    assert retry.headers["Idempotent-Replayed"] == "true"
    assert retry.json()["id"] == first.json()["id"]
    assert _order_count(app) == 1


def test_same_key_with_different_body_is_rejected(
    app: FastAPI, client: TestClient, order_payload: dict
) -> None:
    headers = {"Idempotency-Key": "checkout-7f3a"}
    client.post("/orders", json=order_payload, headers=headers)
    order_payload["items"][0]["quantity"] = 5

    response = client.post("/orders", json=order_payload, headers=headers)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "IDEMPOTENCY_KEY_REUSED"
    assert _order_count(app) == 1


def test_requests_without_key_are_not_deduplicated(
    app: FastAPI, client: TestClient, order_payload: dict[str, object]
) -> None:
    first = client.post("/orders", json=order_payload)
    second = client.post("/orders", json=order_payload)

    assert first.json()["id"] != second.json()["id"]
    assert _order_count(app) == 2


def test_concurrent_duplicate_loses_race_and_replays_winner(
    app: FastAPI, client: TestClient, order_payload: dict[str, object], monkeypatch
) -> None:
    """Simulates two requests with the same key passing the pre-check at the same time
    (e.g. one served by Lambda and one by ECS during the canary): the UNIQUE constraint
    rejects the second insert and the loser returns the winner's order."""
    headers = {"Idempotency-Key": "race-1"}
    winner = client.post("/orders", json=order_payload, headers=headers).json()

    real_lookup = service.find_by_idempotency_key
    calls = {"n": 0}

    def lookup_misses_first_time(session, key):
        calls["n"] += 1
        return None if calls["n"] == 1 else real_lookup(session, key)

    monkeypatch.setattr(service, "find_by_idempotency_key", lookup_misses_first_time)

    response = client.post("/orders", json=order_payload, headers=headers)

    assert response.status_code == 200
    assert response.json()["id"] == winner["id"]
    assert calls["n"] == 2
    assert _order_count(app) == 1


def test_key_can_be_made_mandatory(order_payload: dict[str, object]) -> None:
    from orders_api.main import create_app
    from orders_api.models import Base

    app = create_app(make_settings(require_idempotency_key=True))
    Base.metadata.create_all(app.state.engine)
    with TestClient(app) as client:
        missing = client.post("/orders", json=order_payload)
        present = client.post("/orders", json=order_payload, headers={"Idempotency-Key": "k-1"})
    Base.metadata.drop_all(app.state.engine)
    app.state.engine.dispose()

    assert missing.status_code == 400
    assert missing.json()["error"]["code"] == "IDEMPOTENCY_KEY_REQUIRED"
    assert present.status_code == 201


def test_invalid_idempotency_key_is_rejected(
    client: TestClient, order_payload: dict[str, object]
) -> None:
    response = client.post("/orders", json=order_payload, headers={"Idempotency-Key": "has space"})

    assert response.status_code == 422
