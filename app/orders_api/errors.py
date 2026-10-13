"""Uniform error envelope: {"error": {"code", "message", "request_id", "details"}}."""

import logging

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy import exc as sa_exc
from starlette.exceptions import HTTPException as StarletteHTTPException

from orders_api.schemas import ErrorBody, ErrorDetail, ErrorResponse

logger = logging.getLogger(__name__)

DB_RETRY_AFTER_SECONDS = 5


class ApiError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def error_response(
    request: Request,
    status_code: int,
    code: str,
    message: str,
    details: list[ErrorDetail] | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    body = ErrorResponse(
        error=ErrorBody(
            code=code,
            message=message,
            request_id=getattr(request.state, "request_id", None),
            details=details,
        )
    )
    return JSONResponse(
        status_code=status_code,
        content=body.model_dump(mode="json", exclude_none=True),
        headers=headers,
    )


async def _api_error(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, ApiError)
    return error_response(request, exc.status_code, exc.code, exc.message)


async def _http_error(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, StarletteHTTPException)
    code = {404: "NOT_FOUND", 405: "METHOD_NOT_ALLOWED"}.get(exc.status_code, "HTTP_ERROR")
    return error_response(request, exc.status_code, code, str(exc.detail), headers=exc.headers)


async def _validation_error(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, RequestValidationError)
    # Only location + message are returned; raw input values are never echoed back.
    details = [
        ErrorDetail(field=".".join(str(part) for part in err["loc"]), message=err["msg"])
        for err in exc.errors()
    ]
    return error_response(
        request,
        status.HTTP_422_UNPROCESSABLE_CONTENT,
        "VALIDATION_ERROR",
        "Request validation failed.",
        details=details,
    )


async def _database_unavailable(request: Request, exc: Exception) -> JSONResponse:
    # Connection refused, failover in progress, pool exhausted, statement timeout.
    # 503 + Retry-After tells well-behaved clients to back off instead of hammering.
    logger.error("database unavailable", exc_info=exc)
    return error_response(
        request,
        status.HTTP_503_SERVICE_UNAVAILABLE,
        "DATABASE_UNAVAILABLE",
        "The service is temporarily unable to reach its database. Please retry.",
        headers={"Retry-After": str(DB_RETRY_AFTER_SECONDS)},
    )


async def _database_error(request: Request, exc: Exception) -> JSONResponse:
    logger.error("database error", exc_info=exc)
    return error_response(
        request,
        status.HTTP_500_INTERNAL_SERVER_ERROR,
        "DATABASE_ERROR",
        "An unexpected database error occurred.",
    )


def register_exception_handlers(app: FastAPI) -> None:
    app.add_exception_handler(ApiError, _api_error)
    app.add_exception_handler(StarletteHTTPException, _http_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
    for transient in (sa_exc.OperationalError, sa_exc.InterfaceError, sa_exc.TimeoutError):
        app.add_exception_handler(transient, _database_unavailable)
    app.add_exception_handler(sa_exc.SQLAlchemyError, _database_error)
