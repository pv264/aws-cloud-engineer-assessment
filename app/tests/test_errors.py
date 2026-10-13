import json
import logging

import pytest
from fastapi.testclient import TestClient

from orders_api import service
from orders_api.logging_config import JsonFormatter, request_id_ctx


def test_database_outage_returns_503_with_retry_after(
    unavailable_db_client: TestClient, order_payload: dict[str, object]
) -> None:
    response = unavailable_db_client.post("/orders", json=order_payload)

    assert response.status_code == 503
    assert response.headers["Retry-After"] == "5"
    assert response.json()["error"]["code"] == "DATABASE_UNAVAILABLE"


def test_unhandled_exception_returns_json_500(
    client: TestClient, order_payload: dict[str, object], monkeypatch: pytest.MonkeyPatch
) -> None:
    def boom(*_args, **_kwargs):
        raise RuntimeError("unexpected")

    monkeypatch.setattr(service, "create_order", boom)

    response = client.post("/orders", json=order_payload)

    assert response.status_code == 500
    error = response.json()["error"]
    assert error == {
        "code": "INTERNAL_ERROR",
        "message": "An unexpected error occurred.",
        "request_id": response.headers["X-Request-ID"],
    }


def test_json_formatter_includes_request_id_and_extras() -> None:
    record = logging.LogRecord("orders_api", logging.INFO, __file__, 1, "hello", (), None)
    record.order_id = "o-1"
    token = request_id_ctx.set("req-1")
    try:
        line = json.loads(JsonFormatter().format(record))
    finally:
        request_id_ctx.reset(token)

    assert line["message"] == "hello"
    assert line["level"] == "INFO"
    assert line["request_id"] == "req-1"
    assert line["order_id"] == "o-1"
