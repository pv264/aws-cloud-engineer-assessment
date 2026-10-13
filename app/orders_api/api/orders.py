import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response, status
from sqlalchemy.orm import Session

from orders_api import service
from orders_api.config import Settings
from orders_api.database import get_session
from orders_api.errors import ApiError
from orders_api.schemas import ErrorResponse, OrderCreate, OrderOut

router = APIRouter(prefix="/orders", tags=["orders"])

SessionDep = Annotated[Session, Depends(get_session)]
IdempotencyKey = Annotated[
    str | None,
    Header(
        alias="Idempotency-Key",
        min_length=1,
        max_length=255,
        pattern=r"^[\x21-\x7e]+$",
        description="Client-generated unique key (e.g. a UUID) that makes retries safe.",
    ),
]

_ERRORS = {
    422: {"model": ErrorResponse, "description": "Validation error or Idempotency-Key reuse"},
    503: {"model": ErrorResponse, "description": "Database temporarily unavailable"},
}


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=OrderOut,
    responses={
        200: {"model": OrderOut, "description": "Idempotent replay of an existing order"},
        400: {"model": ErrorResponse, "description": "Idempotency-Key required"},
        **_ERRORS,
    },
)
def create_order(
    payload: OrderCreate,
    request: Request,
    response: Response,
    session: SessionDep,
    idempotency_key: IdempotencyKey = None,
) -> OrderOut:
    settings: Settings = request.app.state.settings
    if idempotency_key is None and settings.require_idempotency_key:
        raise ApiError(400, "IDEMPOTENCY_KEY_REQUIRED", "The Idempotency-Key header is required.")

    try:
        result = service.create_order(session, payload, idempotency_key)
    except service.IdempotencyKeyReuseError:
        raise ApiError(
            422,
            "IDEMPOTENCY_KEY_REUSED",
            "This Idempotency-Key was already used with a different request body.",
        ) from None

    response.headers["Location"] = f"/orders/{result.order.id}"
    if result.replayed:
        response.status_code = status.HTTP_200_OK
        response.headers["Idempotent-Replayed"] = "true"
    return OrderOut.model_validate(result.order)


@router.get(
    "/{order_id}",
    response_model=OrderOut,
    responses={404: {"model": ErrorResponse, "description": "Order not found"}, **_ERRORS},
)
def get_order(order_id: uuid.UUID, session: SessionDep) -> OrderOut:
    order = service.get_order(session, order_id)
    if order is None:
        raise ApiError(404, "ORDER_NOT_FOUND", f"Order {order_id} was not found.")
    return OrderOut.model_validate(order)
