"""Alembic environment.

Production runs migrations as a one-off ECS task (same image, command
`alembic upgrade head`) before the service is updated, never on application start-up:
N tasks starting at once must not race each other to migrate the schema.

Migrations must be backward compatible (expand -> migrate -> contract) because the old
and new application versions, and during the migration also the legacy Lambda
functions, run against the same schema at the same time.
"""

from alembic import context
from sqlalchemy import create_engine
from sqlalchemy.pool import NullPool

from orders_api.config import Settings
from orders_api.models import Base

target_metadata = Base.metadata
settings = Settings()
url = settings.sqlalchemy_url()


def run_migrations_offline() -> None:
    context.configure(
        url=url.render_as_string(hide_password=False),
        target_metadata=target_metadata,
        literal_binds=True,
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connect_args: dict[str, object] = {}
    if url.get_backend_name() == "postgresql":
        connect_args = {
            "connect_timeout": settings.db_connect_timeout_seconds,
            "application_name": f"{settings.app_name}-migrations",
            "sslmode": url.query.get("sslmode", settings.db_sslmode),
            # Give up quickly instead of queueing behind live traffic for a table lock
            # (a blocked ALTER TABLE blocks every query behind it). Retry the deploy instead.
            "options": "-c lock_timeout=5000 -c statement_timeout=0",
        }
    engine = create_engine(url, poolclass=NullPool, connect_args=connect_args)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
