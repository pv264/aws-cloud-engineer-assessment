"""Application configuration loaded from environment variables (12-factor).

Locally the values come from docker compose / a shell. On ECS, plain settings are
task-definition environment variables and DB_PASSWORD is injected by the ECS agent
from AWS Secrets Manager, so no secret ever lives in the image or in source control.
"""

from functools import lru_cache
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import URL, make_url


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", case_sensitive=False)

    app_name: str = "orders-api"
    app_env: Literal["local", "test", "dev", "staging", "prod"] = "local"
    app_version: str = "0.0.0-dev"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"

    host: str = "0.0.0.0"  # noqa: S104 - containers must listen on all interfaces
    port: int = Field(default=8000, ge=1, le=65535)
    web_concurrency: int = Field(default=2, ge=1, le=32)
    # Must stay below the ECS stopTimeout (30s) so in-flight requests drain before SIGKILL.
    graceful_shutdown_seconds: int = Field(default=25, ge=1)
    # Must stay above the ALB idle timeout (60s), otherwise the ALB can reuse a
    # connection the app just closed and return 502s.
    keep_alive_seconds: int = Field(default=75, ge=1)

    # DATABASE_URL wins when set (local, tests). Otherwise the discrete DB_* values
    # are used, which is how ECS injects the Secrets Manager password.
    database_url: SecretStr | None = None
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "orders"
    db_user: str = "orders"
    db_password: SecretStr = SecretStr("")
    db_sslmode: Literal["disable", "allow", "prefer", "require", "verify-ca", "verify-full"] = (
        "prefer"
    )

    # Connection budget per process = pool_size + max_overflow. Keep it small and
    # fail fast: waiting 30s for a pooled connection only converts DB pressure
    # into ALB 5xx and client retries.
    db_pool_size: int = Field(default=5, ge=1)
    db_max_overflow: int = Field(default=5, ge=0)
    db_pool_timeout_seconds: float = Field(default=3.0, gt=0)
    db_pool_recycle_seconds: int = Field(default=1800, ge=60)
    db_connect_timeout_seconds: int = Field(default=5, ge=1)
    # 0 disables the per-connection statement_timeout. Behind RDS Proxy prefer a
    # role-level setting (ALTER ROLE ... SET statement_timeout) to avoid session pinning.
    db_statement_timeout_ms: int = Field(default=5000, ge=0)

    # When true, POST /orders without an Idempotency-Key header is rejected.
    require_idempotency_key: bool = False

    def sqlalchemy_url(self) -> URL:
        if self.database_url is not None:
            return make_url(self.database_url.get_secret_value())
        return URL.create(
            drivername="postgresql+psycopg",
            username=self.db_user,
            password=self.db_password.get_secret_value() or None,
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
