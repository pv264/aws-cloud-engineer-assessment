import uuid
from datetime import UTC, datetime
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, computed_field

Money = Annotated[Decimal, Field(gt=0, le=Decimal("1000000"), max_digits=9, decimal_places=2)]


def _as_utc(value: datetime) -> datetime:
    # Timestamps are stored as UTC; always emit an explicit offset.
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


UtcDatetime = Annotated[datetime, AfterValidator(_as_utc)]


class OrderItemIn(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    sku: str = Field(
        min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._-]+$", examples=["SKU-123"]
    )
    quantity: int = Field(ge=1, le=1000, examples=[2])
    unit_price: Money = Field(examples=["19.99"])


class OrderCreate(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    customer_id: str = Field(min_length=1, max_length=64, examples=["cust-42"])
    currency: str = Field(default="USD", pattern=r"^[A-Z]{3}$", description="ISO 4217 code")
    items: list[OrderItemIn] = Field(min_length=1, max_length=100)


class OrderItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    sku: str
    quantity: int
    unit_price: Decimal

    @computed_field  # type: ignore[prop-decorator]
    @property
    def line_total(self) -> Decimal:
        return (self.unit_price * self.quantity).quantize(Decimal("0.01"))


class OrderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    customer_id: str
    status: str
    currency: str
    total_amount: Decimal
    items: list[OrderItemOut]
    created_at: UtcDatetime
    updated_at: UtcDatetime


class ErrorDetail(BaseModel):
    field: str
    message: str


class ErrorBody(BaseModel):
    code: str
    message: str
    request_id: str | None = None
    details: list[ErrorDetail] | None = None


class ErrorResponse(BaseModel):
    error: ErrorBody


class LivenessOut(BaseModel):
    status: Literal["ok"]
    service: str
    version: str
    environment: str


class ReadinessOut(BaseModel):
    status: Literal["ok", "unavailable"]
    checks: dict[str, Literal["ok", "unavailable"]]
