import logging
import re
import time
import uuid

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint

from orders_api.errors import error_response
from orders_api.logging_config import request_id_ctx

logger = logging.getLogger("orders_api.access")

# Accept a caller-supplied request id only if it is safe to write into logs.
_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
# ALB health checks hit these every few seconds per target; keep them out of INFO logs.
_QUIET_PATHS = frozenset({"/health", "/health/ready"})


class RequestContextMiddleware(BaseHTTPMiddleware):
    """Assigns a request id, emits one structured access log line, and turns any
    unhandled exception into a JSON 500 instead of a bare text response."""

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        incoming = request.headers.get("x-request-id", "")
        request_id = incoming if _SAFE_REQUEST_ID.match(incoming) else uuid.uuid4().hex
        request.state.request_id = request_id
        token = request_id_ctx.set(request_id)
        started = time.perf_counter()
        try:
            try:
                response = await call_next(request)
            except Exception:
                logger.exception("unhandled exception")
                response = error_response(
                    request, 500, "INTERNAL_ERROR", "An unexpected error occurred."
                )
            response.headers["X-Request-ID"] = request_id

            route = request.scope.get("route")
            level = logging.INFO
            if response.status_code >= 500:
                level = logging.ERROR
            elif request.url.path in _QUIET_PATHS:
                level = logging.DEBUG
            logger.log(
                level,
                "request completed",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "route": getattr(route, "path", None),
                    "status": response.status_code,
                    "duration_ms": round((time.perf_counter() - started) * 1000, 2),
                    "client_ip": request.client.host if request.client else None,
                    "amzn_trace_id": request.headers.get("x-amzn-trace-id"),
                },
            )
            return response
        finally:
            request_id_ctx.reset(token)
