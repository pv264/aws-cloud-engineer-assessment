# syntax=docker/dockerfile:1.7
#
# Orders API image. Build context is ./app:
#   docker build -f docker/Dockerfile -t orders-api:local app
#
# Base image: official Debian "trixie" slim Python, pinned by multi-arch index digest
# so builds are reproducible. Renovate/Dependabot bumps the digest; CI rebuilds and
# re-scans. The same digest covers linux/amd64 and linux/arm64 (Graviton).
ARG PYTHON_IMAGE=python:3.13-slim-trixie@sha256:70729b46c69b4f1e97c4822c1af3df53a1476cf5ddc6c087c0c10bc3a5678c2f

########################################################################################
# Stage 1: build a self-contained virtualenv. Nothing from this stage except /opt/venv
# reaches the final image (no pip cache, no build tooling).
########################################################################################
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

# The venv gets no pip of its own: the builder's pip installs into it via --python,
# so the package manager never ships in the runtime image.
RUN python -m venv --without-pip /opt/venv

# Dependencies first so this layer is cached until requirements.txt changes.
# --require-hashes: every artifact must match the hash in the lock file
# (protects against a compromised or tampered package index).
COPY requirements.txt /tmp/requirements.txt
RUN pip --python /opt/venv/bin/python install --require-hashes --no-deps -r /tmp/requirements.txt

########################################################################################
# Stage 2: minimal runtime.
########################################################################################
FROM ${PYTHON_IMAGE} AS runtime

ARG APP_VERSION=0.0.0-dev
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="orders-api" \
      org.opencontainers.image.description="XYZZ order-management API" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

# - Pick up Debian security fixes released after the base image was built.
# - Remove the base image's own pip: the app never needs it at runtime, and its
#   vendored libraries (urllib3, msgpack...) are the main source of scanner findings.
# - Create an unprivileged user.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall --yes --quiet pip \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8000

COPY --from=builder /opt/venv /opt/venv

WORKDIR /srv
# Owned by root and not writable by the app user: the code cannot be modified at
# runtime. On ECS the root filesystem is also mounted read-only.
COPY alembic.ini ./
COPY migrations ./migrations
COPY orders_api ./orders_api

USER 10001:10001
EXPOSE 8000

# Local/docker-compose health check (ECS uses the equivalent healthCheck in the task
# definition; the ALB uses its own target-group check on the same endpoint).
# Python stdlib instead of curl keeps curl, and its CVEs, out of the image.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ.get('PORT', '8000'), timeout=2)"]

# Exec form: python is PID 1 and receives SIGTERM directly from ECS, so uvicorn drains
# in-flight requests (graceful_shutdown_seconds) before the task stops.
CMD ["python", "-m", "orders_api"]
