"""Order business logic, including idempotent creation.

Idempotency design:
  * Clients send an `Idempotency-Key` header (e.g. a UUID generated per checkout attempt).
  * The key is stored on the order row under a UNIQUE constraint, in the same
    transaction that creates the order, so there is no window where the order exists
    without its key (or the other way round).
  * A retry with the same key and the same body returns the original order.
    The same key with a different body is rejected.
  * Two concurrent requests with the same key race on the UNIQUE constraint; the
    loser rolls back and returns the winner's order. Because the guard lives in the
    shared database and not in process memory, it holds across every ECS task and
    across the legacy Lambda stack while both serve traffic during the migration.
"""

import hashlib
import json
import logging
import uuid
from dataclasses import dataclass
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from orders_api.models import Order, OrderItem
from orders_api.schemas import OrderCreate

logger = logging.getLogger(__name__)

CENT = Decimal("0.01")


class IdempotencyKeyReuseError(Exception):
    """The Idempotency-Key was already used with a different request body."""


@dataclass(frozen=True)
class CreateOrderResult:
    order: Order
    replayed: bool


def request_fingerprint(payload: OrderCreate) -> str:
    canonical = json.dumps(payload.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def find_by_idempotency_key(session: Session, key: str) -> Order | None:
    return session.scalar(select(Order).where(Order.idempotency_key == key))


def _replay(existing: Order, fingerprint: str) -> CreateOrderResult:
    if existing.request_fingerprint != fingerprint:
        raise IdempotencyKeyReuseError
    logger.info("idempotent replay", extra={"order_id": str(existing.id)})
    return CreateOrderResult(order=existing, replayed=True)


def create_order(
    session: Session, payload: OrderCreate, idempotency_key: str | None
) -> CreateOrderResult:
    fingerprint = request_fingerprint(payload) if idempotency_key else None

    if idempotency_key and fingerprint:
        existing = find_by_idempotency_key(session, idempotency_key)
        if existing is not None:
            return _replay(existing, fingerprint)

    total = sum((item.unit_price * item.quantity for item in payload.items), Decimal(0))
    order = Order(
        customer_id=payload.customer_id,
        currency=payload.currency,
        total_amount=total.quantize(CENT),
        idempotency_key=idempotency_key,
        request_fingerprint=fingerprint,
        items=[
            OrderItem(sku=item.sku, quantity=item.quantity, unit_price=item.unit_price)
            for item in payload.items
        ],
    )
    session.add(order)
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        if not (idempotency_key and fingerprint):
            raise
        # Lost the race against a concurrent request carrying the same key.
        existing = find_by_idempotency_key(session, idempotency_key)
        if existing is None:
            raise
        return _replay(existing, fingerprint)

    logger.info(
        "order created",
        extra={
            "order_id": str(order.id),
            "customer_id": order.customer_id,
            "item_count": len(order.items),
        },
    )
    return CreateOrderResult(order=order, replayed=False)


def get_order(session: Session, order_id: uuid.UUID) -> Order | None:
    return session.get(Order, order_id)
