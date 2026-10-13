"""Test fixtures.

By default the suite runs against in-memory SQLite, so `pytest` needs no services.
CI also runs it against a real PostgreSQL by setting TEST_DATABASE_URL, e.g.
    TEST_DATABASE_URL=postgresql+psycopg://orders:orders@localhost:5432/orders_test
"""

import os
from collections.abc import Iterator

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from orders_api.config import Settings
from orders_api.main import create_app
from orders_api.models import Base

# Nothing listens on port 9 (discard), so connections are refused immediately.
UNREACHABLE_DB_URL = "postgresql+psycopg://orders:unused@127.0.0.1:9/orders"


def make_settings(**overrides: object) -> Settings:
    values: dict[str, object] = {
        "app_env": "test",
        "app_version": "test",
        "log_level": "WARNING",
        "database_url": os.getenv("TEST_DATABASE_URL", "sqlite+pysqlite:///:memory:"),
        "db_sslmode": "disable",
    }
    values.update(overrides)
    return Settings.model_validate(values)


@pytest.fixture
def settings() -> Settings:
    return make_settings()


@pytest.fixture
def app(settings: Settings) -> Iterator[FastAPI]:
    application = create_app(settings)
    engine = application.state.engine
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    yield application
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture
def client(app: FastAPI) -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def unavailable_db_client() -> Iterator[TestClient]:
    application = create_app(
        make_settings(database_url=UNREACHABLE_DB_URL, db_connect_timeout_seconds=1)
    )
    with TestClient(application) as test_client:
        yield test_client


@pytest.fixture
def order_payload() -> dict[str, object]:
    return {
        "customer_id": "cust-42",
        "currency": "USD",
        "items": [
            {"sku": "SKU-1", "quantity": 2, "unit_price": "19.99"},
            {"sku": "SKU-2", "quantity": 1, "unit_price": "5.00"},
        ],
    }
