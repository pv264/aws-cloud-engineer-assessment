from collections.abc import Iterator

from fastapi import Request
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from orders_api.config import Settings


def create_db_engine(settings: Settings) -> Engine:
    url = settings.sqlalchemy_url()

    if url.get_backend_name() == "sqlite":
        # Used by the unit tests only.
        in_memory = url.database in (None, "", ":memory:")
        return create_engine(
            url,
            connect_args={"check_same_thread": False},
            poolclass=StaticPool if in_memory else None,
        )

    connect_args: dict[str, object] = {
        "connect_timeout": settings.db_connect_timeout_seconds,
        # Shows up in pg_stat_activity, so connections can be attributed per
        # service and environment (e.g. ECS vs. legacy Lambda during the migration).
        "application_name": f"{settings.app_name}-{settings.app_env}",
    }
    if "sslmode" not in url.query:
        connect_args["sslmode"] = settings.db_sslmode
    if settings.db_statement_timeout_ms > 0:
        connect_args["options"] = f"-c statement_timeout={settings.db_statement_timeout_ms}"

    return create_engine(
        url,
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_timeout=settings.db_pool_timeout_seconds,
        pool_recycle=settings.db_pool_recycle_seconds,
        # Detects connections killed by a Multi-AZ failover or RDS Proxy idle timeout.
        pool_pre_ping=True,
        connect_args=connect_args,
    )


def get_session(request: Request) -> Iterator[Session]:
    with request.app.state.session_factory() as session:
        yield session
