"""Health endpoints.

GET /health        Liveness. No dependencies. Used by the ALB target group and the
                   container health check. It deliberately does NOT touch the database:
                   if it did, a short RDS failover would mark every task unhealthy at
                   once, the ALB would return 503 for everything, and ECS would start
                   replacing healthy tasks.
GET /health/ready  Readiness / deep check (database round trip). Used by deploy smoke
                   tests, synthetic canaries and humans, not by the load balancer.
"""

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response, status
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from orders_api.config import Settings
from orders_api.database import get_session
from orders_api.schemas import LivenessOut, ReadinessOut

router = APIRouter(prefix="/health", tags=["health"])
logger = logging.getLogger(__name__)


# `async def` runs on the event loop rather than the worker thread pool, so liveness
# still answers when every pool thread is blocked on slow database calls.
@router.get("", response_model=LivenessOut)
async def liveness(request: Request) -> LivenessOut:
    settings: Settings = request.app.state.settings
    return LivenessOut(
        status="ok",
        service=settings.app_name,
        version=settings.app_version,
        environment=settings.app_env,
    )


@router.get(
    "/ready",
    response_model=ReadinessOut,
    responses={503: {"model": ReadinessOut, "description": "A dependency is unavailable"}},
)
def readiness(
    response: Response, session: Annotated[Session, Depends(get_session)]
) -> ReadinessOut:
    try:
        session.execute(text("SELECT 1"))
    except SQLAlchemyError:
        logger.warning("readiness check failed: database unreachable", exc_info=True)
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return ReadinessOut(status="unavailable", checks={"database": "unavailable"})
    return ReadinessOut(status="ok", checks={"database": "ok"})
