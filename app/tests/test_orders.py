import uuid

import pytest
from fastapi.testclient import TestClient


def test_create_order_returns_201_with_location(
    client: TestClient, order_payload: dict[str, object]
) -> None:
    response = client.post("/orders", json=order_payload)

    assert response.status_code == 201
    body = response.json()
    assert response.headers["Location"] == f"/orders/{body['id']}"
    assert body["customer_id"] == "cust-42"
    assert body["status"] == "PENDING"
    assert body["currency"] == "USD"
    assert body["total_amount"] == "44.98"
    assert [item["line_total"] for item in body["items"]] == ["39.98", "5.00"]
    assert "Idempotent-Replayed" not in response.headers


def test_get_order_round_trip(client: TestClient, order_payload: dict[str, object]) -> None:
    created = client.post("/orders", json=order_payload).json()

    response = client.get(f"/orders/{created['id']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_unknown_order_returns_404_envelope(client: TestClient) -> None:
    response = client.get(f"/orders/{uuid.uuid4()}")

    assert response.status_code == 404
    error = response.json()["error"]
    assert error["code"] == "ORDER_NOT_FOUND"
    assert error["request_id"] == response.headers["X-Request-ID"]


def test_get_order_with_malformed_id_is_rejected(client: TestClient) -> None:
    response = client.get("/orders/not-a-uuid")

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


@pytest.mark.parametrize(
    ("mutate", "field"),
    [
        (lambda p: p.update(items=[]), "body.items"),
        (lambda p: p["items"][0].update(quantity=0), "body.items.0.quantity"),
        (lambda p: p["items"][0].update(unit_price="-1.00"), "body.items.0.unit_price"),
        (lambda p: p["items"][0].update(unit_price="1.999"), "body.items.0.unit_price"),
        (lambda p: p["items"][0].update(sku="bad sku!"), "body.items.0.sku"),
        (lambda p: p.update(currency="usd"), "body.currency"),
        (lambda p: p.update(customer_id=""), "body.customer_id"),
        (lambda p: p.update(unexpected="x"), "body.unexpected"),
        (lambda p: p.pop("customer_id"), "body.customer_id"),
    ],
)
def test_invalid_payloads_are_rejected(
    client: TestClient, order_payload: dict, mutate, field: str
) -> None:
    mutate(order_payload)

    response = client.post("/orders", json=order_payload)

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "VALIDATION_ERROR"
    assert field in [detail["field"] for detail in error["details"]]


def test_malformed_json_is_rejected(client: TestClient) -> None:
    response = client.post(
        "/orders", content=b"{not json", headers={"Content-Type": "application/json"}
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_safe_request_id_is_propagated(client: TestClient) -> None:
    response = client.get("/health", headers={"X-Request-ID": "abc-123"})

    assert response.headers["X-Request-ID"] == "abc-123"


def test_unsafe_request_id_is_replaced(client: TestClient) -> None:
    response = client.get("/health", headers={"X-Request-ID": "evil\tinjected=1"})

    assert response.headers["X-Request-ID"] != "evil\tinjected=1"
    assert len(response.headers["X-Request-ID"]) == 32


def test_unknown_route_uses_error_envelope(client: TestClient) -> None:
    response = client.get("/nope")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"
