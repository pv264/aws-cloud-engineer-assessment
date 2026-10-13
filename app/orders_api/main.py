import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy.orm import sessionmaker

from orders_api.api import health, orders
from orders_api.config import Settings, get_settings
from orders_api.database import create_db_engine
from orders_api.errors import register_exception_handlers
from orders_api.logging_config import configure_logging
from orders_api.middleware import RequestContextMiddleware

logger = logging.getLogger(__name__)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)

    # create_engine() is lazy: no connection is opened until the first query, so a
    # database outage never stops the process from starting and answering /health.
    engine = create_db_engine(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        logger.info(
            "application started",
            extra={"environment": settings.app_env, "version": settings.app_version},
        )
        yield
        engine.dispose()
        logger.info("application stopped")

    public_docs = settings.app_env != "prod"
    app = FastAPI(
        title="Orders API",
        version=settings.app_version,
        lifespan=lifespan,
        docs_url="/docs" if public_docs else None,
        redoc_url=None,
        openapi_url="/openapi.json" if public_docs else None,
    )
    app.state.settings = settings
    app.state.engine = engine
    app.state.session_factory = sessionmaker(engine, expire_on_commit=False)

    app.add_middleware(RequestContextMiddleware)
    register_exception_handlers(app)
    app.include_router(health.router)
    app.include_router(orders.router)
    return app
