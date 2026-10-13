"""Container entrypoint: `python -m orders_api`."""

import uvicorn

from orders_api.config import get_settings
from orders_api.logging_config import configure_logging


def main() -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    uvicorn.run(
        "orders_api.main:create_app",
        factory=True,
        host=settings.host,
        port=settings.port,
        workers=settings.web_concurrency,
        # Tasks only accept traffic from the ALB security group, so trusting
        # X-Forwarded-* from any peer is safe here and gives real client IPs.
        proxy_headers=True,
        forwarded_allow_ips="*",
        timeout_keep_alive=settings.keep_alive_seconds,
        timeout_graceful_shutdown=settings.graceful_shutdown_seconds,
        log_config=None,
        access_log=False,
        server_header=False,
    )


if __name__ == "__main__":
    main()
