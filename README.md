# XYZZ Orders Platform: AWS Cloud Engineer Assessment

Moving XYZZ's order API from **API Gateway → Lambda** to **ALB → ECS Fargate → RDS
PostgreSQL**, with zero downtime and a rollback at every step. Work that is better
served by serverless (async jobs, schedules, static content) stays serverless.

![Target architecture](architecture/architecture-diagram.png)

## Contents

| Deliverable | Where |
|---|---|
| Architecture diagram + design (HA, scaling, failure handling, what stays serverless) | [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md), [diagram](architecture/architecture-diagram.png) |
| FastAPI order service + tests | [app/](app/) |
| Docker (multi-stage, non-root, hash-pinned) + local stack | [docker/Dockerfile](docker/Dockerfile), [docker/docker-compose.yml](docker/docker-compose.yml) |
| Terraform (10 modules, 3 environments, bootstrap, tests) | [terraform/](terraform/), [terraform/README.md](terraform/README.md) |
| CI/CD (GitHub Actions) | [.github/workflows/](.github/workflows/) |
| Migration strategy | [MIGRATION.md](MIGRATION.md) |
| Migration incident analysis (75/25 split) | [MIGRATION_INCIDENT.md](MIGRATION_INCIDENT.md) |
| Production troubleshooting (503 after deploy) | [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) |
| Security | [SECURITY.md](SECURITY.md) |
| Scalability and HA (5k → 50k users) | [SCALABILITY.md](SCALABILITY.md) |
| Monitoring and alerts | [MONITORING.md](MONITORING.md) |
| Cost optimization | [COST_OPTIMIZATION.md](COST_OPTIMIZATION.md) |
| Final engineering questions | [below](#final-engineering-questions) |

## Repository layout

```
.
├── README.md
├── architecture/           ARCHITECTURE.md, architecture-diagram.{png,svg}, generate_diagram.py
├── app/                    FastAPI service
│   ├── orders_api/         config, database, models, schemas, service (idempotency), middleware, errors, api/
│   ├── migrations/         Alembic (run as a one-off task, never on start-up)
│   ├── tests/              pytest (SQLite by default, PostgreSQL in CI)
│   ├── requirements.in / requirements.txt (hash-locked) / requirements-dev.txt
│   └── pyproject.toml      ruff, pytest, coverage settings
├── docker/                 Dockerfile, docker-compose.yml, .env.example
├── compose.yaml            lets `docker compose up` work from the repo root
├── terraform/              root module, modules/, environments/, bootstrap/, tests/
├── .github/workflows/      ci.yml, deploy.yml, deploy-environment.yml, terraform-plan.yml
├── scripts/smoke-test.sh   used by CI and after every deployment
├── Makefile                shortcuts for everything below
└── MIGRATION.md, MIGRATION_INCIDENT.md, INCIDENT_RESPONSE.md, SECURITY.md,
    SCALABILITY.md, MONITORING.md, COST_OPTIMIZATION.md
```

## Architecture and key decisions

```
Users ─► Route 53 ─► WAF ─► ALB (public, 3 AZs) ─► ECS Fargate (private, 3 AZs, auto scaling)
      ─► RDS Proxy ─► RDS PostgreSQL Multi-AZ (isolated subnets, no internet route)
Async: order outbox ─► SQS ─► Lambda workers;  EventBridge Scheduler ─► Lambda;  S3 + CloudFront for static
```

| Decision | Why | Alternative considered |
|---|---|---|
| **ECS on Fargate** for the API | Stateless HTTP service, no hosts to patch, per-task isolation, native ALB/IAM integration, scales in seconds | EC2/ECS-on-EC2 (only worth it at very high steady utilization); EKS (operational cost with no benefit here) |
| **Keep serverless where it fits** | SQS + Lambda for spiky async side effects, Scheduler + Lambda for cron, S3 + CloudFront for static | Running everything in containers wastes idle capacity |
| **RDS Proxy** | ECS pools plus Lambda concurrency would exhaust `max_connections`, the classic failure of this migration | Bigger instance (doesn't fix storms) |
| **Shared single database during the migration** | No dual writes: consistency by design, and every rollback is a routing change | Separate DBs + sync (two sources of truth) |
| **ALB weighted target groups (Lambda + ECS)** for the canary | Per-request, instant, no DNS caching; rollback in seconds | Route 53 weighted records (coarse, cached), used only for the front-door move |
| **Idempotency-Key stored with the order under a UNIQUE constraint** | Safe retries across tasks *and* across both stacks during the migration | In-memory or per-stack stores (break when a retry changes stack) |
| **Shallow `/health` for the ALB, deep `/health/ready` for humans/canaries** | A DB blip must not mark every task unhealthy (that turns into a full 503 outage) | DB check in the LB health check |
| **Graviton (ARM64)** | ~20% cheaper; the multi-arch image is built anyway | x86 |
| **Terraform: one root module, per-environment tfvars + backends, separate accounts** | Same code in every environment; isolated state and blast radius | Workspaces, copied environment folders |
| **GitHub OIDC, no stored AWS keys; build once, promote the same digest** | Supply-chain integrity and least privilege per job | Long-lived access keys, rebuilding per environment |

## Running locally

**Prerequisites:** Docker with Compose v2. For running without Docker: Python 3.13.
For the infrastructure: Terraform ≥ 1.11.

### With Docker (recommended)

```bash
docker compose up --build        # from the repo root (or: cd docker && docker compose up --build)
# PostgreSQL starts → `alembic upgrade head` runs once → the API starts when the schema is ready
open http://localhost:8000/docs  # interactive OpenAPI docs (disabled in prod)
./scripts/smoke-test.sh http://localhost:8000
docker compose down -v
```

### API examples

```bash
# Create an order (Idempotency-Key makes retries safe)
curl -i -X POST localhost:8000/orders \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: 4f1c7a52-checkout-1' \
  -d '{"customer_id":"cust-42","currency":"USD","items":[{"sku":"SKU-1","quantity":2,"unit_price":"19.99"}]}'
# → 201 Created, Location: /orders/<id>, {"id": ..., "total_amount": "39.98", "status": "PENDING", ...}

# Same request again (a client retry) → 200 OK, Idempotent-Replayed: true, same order id
# Same key, different body → 422 IDEMPOTENCY_KEY_REUSED

curl localhost:8000/orders/<id>     # 200, or 404 {"error":{"code":"ORDER_NOT_FOUND",...}}
curl localhost:8000/health          # liveness: {"status":"ok","service":"orders-api",...}
curl localhost:8000/health/ready    # readiness: checks the database, 503 if unreachable
```

| Endpoint | Success | Errors |
|---|---|---|
| `POST /orders` | `201` + `Location`; `200` + `Idempotent-Replayed: true` on replay | `422` validation / key reuse, `400` key required (if enforced), `503` + `Retry-After` DB unavailable |
| `GET /orders/{id}` | `200` | `404`, `422` (malformed UUID), `503` |
| `GET /health` | `200` (no dependencies) | n/a |
| `GET /health/ready` | `200` | `503` when the database is unreachable |

Every response carries `X-Request-ID`. Errors share one envelope:
`{"error": {"code", "message", "request_id", "details"?}}`.

### Without Docker

```bash
make venv && make lint && make test   # tests use in-memory SQLite; no services needed
# Against PostgreSQL:
TEST_DATABASE_URL=postgresql+psycopg://orders:local-dev-only@localhost:5432/orders make test
```

### Application design

- **Configuration:** 12-factor environment variables via `pydantic-settings`
  ([`config.py`](app/orders_api/config.py)): `APP_ENV`, `LOG_LEVEL`, `DB_*` or
  `DATABASE_URL`, pool sizes and timeouts, `WEB_CONCURRENCY`, `REQUIRE_IDEMPOTENCY_KEY`.
  Invalid config fails at start-up, not on the first request.
- **Validation:** Pydantic models with `extra="forbid"`, bounded lengths and amounts,
  money as `Decimal` (serialized as strings), ISO currency codes.
- **Error handling:** domain errors (404/422/400), validation errors (422 with field
  paths, no input echo), **database failures → 503 + `Retry-After`** (pool exhausted,
  connection refused, failover), anything unexpected → JSON 500 with the request id.
- **Database:** SQLAlchemy 2 + psycopg 3. Each worker has a bounded pool with
  `pool_pre_ping`, fail-fast timeouts (3 s pool wait, 5 s connect/statement), and
  `application_name` for attribution in `pg_stat_activity`. Constraints live in the
  schema (unique idempotency key, CHECKs, FKs). Alembic migrations are verified in CI with
  `alembic check` (models and migrations cannot drift).
- **Logging:** one JSON line per event to stdout, with `request_id`, the ALB trace id,
  route, status and duration. Health checks are logged at DEBUG.
- **Operability:** graceful shutdown (25 s) inside ECS's 30 s stop timeout; keep-alive
  75 s > ALB idle 60 s; liveness runs on the event loop so it answers even when the
  worker thread pool is saturated.

## Docker

| Question | Answer |
|---|---|
| **Base image** | `python:3.13-slim-trixie`, **pinned by multi-arch digest**. Official, Debian-based (glibc, so prebuilt `manylinux` wheels such as psycopg-binary and pydantic-core just work), small, patched regularly. Alpine was rejected (musl means source builds and slower, larger builds). Distroless was considered; it ties the Python version to the distro release and makes debugging harder, for a modest size gain over slim with pip removed |
| **Optimization** | Multi-stage build: dependencies install into a venv in a builder stage and only the venv and code are copied. The dependency layer is cached separately from the code. `.dockerignore` is an allow-list. uvicorn without the `[standard]` extras (no reload/websocket packages). **pip removed** from the runtime image. Result: ~90 MB of dependencies on the slim base, no compilers |
| **Supply chain** | `pip install --require-hashes` against a fully hashed lock file (`uv pip compile --generate-hashes`); base image digest pinned; Dependabot keeps both current; hadolint + Trivy in CI (0 fixable HIGH/CRITICAL findings at the time of writing) |
| **Configuration** | Environment variables only; the same image runs in every environment. `APP_VERSION` is baked in at build time (git SHA) |
| **Secrets** | Never in the image or the compose file. On ECS the DB credentials come from **Secrets Manager**, injected by the ECS agent at task start (the task definition holds only the ARN). Locally, `docker-compose.yml` uses a clearly labelled, local-only default (`local-dev-only`) for a throwaway database bound to `127.0.0.1`, overridable via a git-ignored `docker/.env` |
| **Health checks** | Three layers on the same shallow `/health` endpoint. (1) Docker `HEALTHCHECK` (local/compose) uses Python's stdlib, so no curl in the image. (2) The ECS container `healthCheck` restarts hung processes. (3) The ALB target-group check controls routing. `/health/ready` (DB round trip) is for smoke tests and canaries |
| **Runtime hardening** | Non-root UID 10001, code owned by root, read-only root filesystem (+ `/tmp` volume), all capabilities dropped, `no-new-privileges`, init process for signal handling |
| **Deploying to AWS** | CI builds **one** `linux/amd64` + `linux/arm64` image tagged with the git SHA (immutable ECR tag, SBOM + provenance), then promotes **the same digest** dev → staging → prod. Per environment it registers a new task definition revision, runs `alembic upgrade head` as a one-off Fargate task with the same image, updates the ECS service (rolling, min healthy 100%, circuit breaker + alarm rollback), and smoke tests the public URL |

## AWS deployment

### 1. Bootstrap (once per account)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var github_owner=<github-org>
# → state bucket, ECR repository, GitHub OIDC provider and roles
```

### 2. GitHub configuration

- Repository variables: `AWS_REGION`, `ECR_REPOSITORY`, and `AWS_ACCOUNT_IDS` (JSON map
  `{"tooling": "...", "dev": "...", "staging": "...", "prod": "..."}`). No secrets are needed.
- GitHub environments `dev`, `staging` and `prod`. `prod` has **required reviewers** and
  allows deployments from `main` only.

### 3. Deploy

Merge to `main`. [`deploy.yml`](.github/workflows/deploy.yml) runs CI, builds and pushes
the image, and deploys to dev, then staging, then prod (after approval of the prod plan).

For a manual first run of an environment, see [terraform/README.md](terraform/README.md#usage):

```bash
cd terraform
terraform init -backend-config=environments/dev.s3.tfbackend
terraform apply -var-file=environments/dev.tfvars -var container_image=<ecr-uri>:<git-sha>
```

## Terraform usage

See [terraform/README.md](terraform/README.md) for state, locking, secrets, environments
and the production change process. In short:

- **Modules:** `network`, `security_groups`, `kms`, `s3_bucket`, `certificate`, `alb`,
  `waf`, `ecs_service`, `rds`, `monitoring`. The root `main.tf` composes them.
- **Environments:** `environments/{dev,staging,prod}.tfvars` + `*.s3.tfbackend`. Same
  code, different inputs; one state file per environment (ideally one account each).
- **State:** S3 (versioned, KMS, TLS-only) with **native S3 locking** (`use_lockfile`).
- **Quality gates:** `fmt`, `validate`, **`terraform test`** (mocked AWS provider runs
  dev, prod and the migration canary settings end to end, plus negative tests for invalid
  input), TFLint, **Checkov** (0 failed; every skip justified inline).

## CI/CD

```
PR ───────► CI: ruff · pytest on PostgreSQL (98% coverage) · alembic upgrade/check/downgrade · pip-audit
             hadolint · docker build · Trivy · docker compose smoke test
             terraform fmt/validate/test · TFLint · Checkov · gitleaks
           + Terraform plan for dev/staging/prod in the job summary (read-only role)

main ─────► CI ─► build multi-arch image (git SHA, digest, SBOM, provenance) ─► ECR
              ─► dev ─► staging ─► [approval] ─► prod
                 each: terraform plan (saved) ─► apply that plan ─► register task def
                       ─► migration task (must exit 0) ─► ECS rolling deploy (wait for COMPLETED)
                       ─► smoke test ─► on failure: roll back to the previous task definition

daily ────► terraform plan per environment (drift detection; fails on drift)
```

**Rollback strategy if a deployment fails:**

1. **Before production:** a release must pass CI and then deploy and smoke-test cleanly in
   dev and staging with the *same* image digest.
2. **During a rollout (automatic):** the ECS **deployment circuit breaker** rolls back
   when new tasks can't become healthy. **CloudWatch alarm rollback** (5xx rate, p99
   latency) rolls back when the new version is healthy but bad. Minimum healthy 100%
   means old tasks keep serving throughout.
3. **After the rollout (pipeline):** if the smoke test fails, the pipeline re-points the
   service at the **previous task definition** and waits for stability.
4. **Later (manual):** run the Deploy workflow with `image_tag=<previous git SHA>`. Images are
   immutable and retained (last 100), so any known-good version can be redeployed
   through the same gates (prod still needs approval).
5. **Database:** migrations are backward compatible (expand/contract) and run before the
   rollout, so rolling the application back never requires rolling the schema back.
   Destructive changes ship in a later release, after the old code is gone.
6. **Infrastructure:** revert the commit and let the pipeline plan and apply. State is
   versioned in S3 if it ever needs restoring.

## Migration approach (summary)

Details: [MIGRATION.md](MIGRATION.md). Strangler-fig, one variable at a time:

1. Build the platform (ECS at 0% traffic).
2. Move the database behind RDS Proxy as the **single shared DB**, using logical
   replication with a seconds-long write pause that clients absorb through retries with idempotency keys.
3. Dark launch: header-routed internal traffic to ECS in prod.
4. Move the front door from API Gateway to the ALB (Lambda behind the ALB, Route 53 weights).
5. Canary with ALB weights: 1 → 5 → 25 → 50 → 100%, with gates on 5xx, p99, duplicates and DB connections.
6. Two-week bake with Lambda kept warm at weight 0.
7. Decommission.

Every rollback is a weight or DNS change, never a data change.

## Troubleshooting approach (summary)

Details: [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) and
[MIGRATION_INCIDENT.md](MIGRATION_INCIDENT.md).

1. Mitigate first: roll back the release or the traffic weight if the change is the trigger.
2. Read the status code carefully: an ALB-generated 503 means no healthy targets, while an
   app-generated 503 means the database is unavailable.
3. Work outward in layers: target health reasons → ECS service events and stopped-task
   reasons → app logs → CPU/memory → security groups and ports → DB connectivity and
   connection budget → auto scaling → deployment configuration diff.
4. Confirm the root cause by switching it on and off. Prevent recurrence with a test or
   guard rail, not a note.

## Final engineering questions

### Q1. First five things I would do before making any production changes

1. **Map the system as it really is.**
   - Inventory API Gateway (routes, authorizers, usage plans, throttling, mappings, custom
     domain) and every Lambda (triggers including non-HTTP ones, timeouts, concurrency,
     retries, IAM, VPC, env/secrets).
   - Inventory the database (engine, size, `max_connections`, how Lambda connects) and all
     clients (retry behaviour, timeouts, hard-coded endpoints).
   - Read the IaC and compare it with the console to find drift.
   - The result is a list of every behaviour the new stack must reproduce or deliberately retire.
2. **Measure a baseline and agree on SLOs.**
   - Collect two to four weeks of RPS, p50/p99 per route, error rates, Lambda concurrency
     and cold starts, DB connections and load, and cost.
   - These numbers become the go/no-go gates. Without them "it seems fine" is the only test.
3. **Make the current system observable and safe to change.**
   - Dashboards and alarms where they are missing, and structured logs with request ids.
   - Verify that backups/PITR actually restore (do a test restore).
   - Confirm that a change and rollback process exists.
   - I don't migrate something I can't see.
4. **Pin down behaviour with tests before touching it.**
   - A black-box contract test suite (status codes, payloads, money and time formats,
     errors, idempotency) that runs against the existing API.
   - A load test of the existing system.
   - The same suites later prove that the ECS stack is equivalent.
5. **Agree the plan, risks and rollback with stakeholders, and rehearse in staging.**
   - Write the phased plan with stop conditions and rollback commands, and review it with
     the team, product, support and security.
   - Choose low-traffic windows and avoid freezes.
   - Build a prod-like staging environment with Terraform and rehearse each phase
     *including its rollback* there.
   - Everything else in this repository is the output of these five steps.

### Q2. Biggest technical risks of moving a production serverless app to containers

| Risk | Why it bites | Mitigation |
|---|---|---|
| **Database connection exhaustion** | Lambda (one connection per invocation) and ECS pools (`tasks × workers × pool`) together exceed `max_connections`; auto scaling makes it worse | RDS Proxy for both, explicit connection budget, small fail-fast pools, connection alarms |
| **Duplicate or lost writes during coexistence** | Retries after timeouts; a retry landing on the other stack; different idempotency mechanisms | One shared DB, a shared `Idempotency-Key` table with a UNIQUE constraint, mandatory keys, reconciliation checks |
| **Hidden API Gateway / Lambda behaviour not carried over** | Authorizers, throttling, request validation, mapping templates, async retries, payload limits (ALB→Lambda 1 MB), binary handling, CORS | Inventory + contract tests against both stacks |
| **Capacity planning moves to us** | Lambda scaled implicitly; containers need right-sized tasks, scaling policies, quotas (Fargate vCPU, IPs), warm-up | Load tests at 2× peak, target tracking on CPU + requests, quota increases, `min_tasks ≥ AZs` |
| **New operational surface** | Health checks, graceful shutdown, timeouts and keep-alive alignment, deployment strategy, image patching | Shallow health checks, aligned timeouts, circuit breaker + alarm rollback, image scanning and rebuilds |
| **Data migration** (if the DB moves too) | Replication lag, sequences, cut-over write pause, rollback after cut-over | Logical replication/DMS with validation, sequence reset, reverse replication, rehearsal |
| **Performance differences** | Different runtime or concurrency model; N+1 queries hidden by Lambda's scaling | Per-route latency gates, Performance Insights, load tests |
| **Security regressions** | A public DB, broad task roles, secrets in env files, open SGs | Isolated subnets, SG chain, Secrets Manager, least-privilege roles, Checkov/Config guard rails |
| **Cost surprises** | Always-on tasks, NAT data processing, interface endpoints, logs | Right-sizing, Graviton, Spot for burst, Savings Plans, endpoint/NAT analysis |
| **Big-bang cut-over** | No way back without data loss | Weighted, reversible, one-variable-at-a-time migration with bake periods |

### Q3. Decision process when the migration causes increased latency and 5xx errors

1. **Assess impact against pre-agreed thresholds** (not gut feeling): error rate and p99
   per target group compared with the Lambda baseline, error-budget burn, business
   metrics (orders/min), and **any sign of data damage** (duplicates, lost writes).
2. **Roll back immediately** (ECS weight → 0, which takes seconds) if *any* hard stop is hit:
   - data integrity issues;
   - 5xx > baseline + 0.5 pp for 5 minutes;
   - p99 > 1.5× baseline for 10 minutes;
   - burn rate > 10×;
   - DB connections or CPU > 80%;
   - a security finding.
   
   With a single shared database, rollback costs nothing and loses nothing. When rollback
   is cheap and the cause is unknown, roll back.
3. **Pause** (hold the current weight, don't advance) when metrics are degraded but within
   gates, the cause is understood or quickly understandable, and there is no customer or
   data harm. For example, a known slow endpoint with a fix in review. Investigate with a
   time box (e.g. 30 minutes); if it isn't resolved by then, roll back.
4. **Continue** only when all gates are green again for a full bake window that includes
   a traffic peak, and the root cause is fixed and verified, not just suspected to be gone.
5. **Investigate on our terms.** After rolling back, keep ECS running at 0% and reproduce
   with header-routed synthetic traffic or in staging under load. Confirm the cause by
   switching it on and off. Restart one step lower (e.g. 5%) with a longer bake.
6. **Communicate and learn:** an incident channel and status updates during the event, a
   blameless review afterwards, and action items that become automated guard rails (for
   example, an alarm that resets the weight during canary steps).

The worked example of this process is in [MIGRATION_INCIDENT.md](MIGRATION_INCIDENT.md).

## Assumptions

- The existing database is PostgreSQL (the migration plan also covers DynamoDB).
- AWS region `us-east-1`; one AWS account per environment plus a tooling account for ECR
  (account ids in tfvars are placeholders, as are the domain names and hosted zone ids).
- The API contract (paths, payloads) must not change for existing clients.
- Authentication was out of scope for the exercise (see limitations).
- The traffic numbers in SCALABILITY.md and the costs in COST_OPTIMIZATION.md are
  modelled assumptions to be replaced by measurements and the AWS Pricing Calculator.

## Verification performed

| Check | Result |
|---|---|
| `pytest` (SQLite and PostgreSQL 17) | 29 passed, 98% coverage |
| `ruff check` / `ruff format --check` | Clean |
| `alembic upgrade head` → `alembic check` → `downgrade base` → `upgrade` on PostgreSQL | Clean, no model/migration drift |
| `docker compose up` (PostgreSQL → migrate → API) + `scripts/smoke-test.sh` | Pass (incl. idempotent replay) |
| DB outage test (stop PostgreSQL) | `/health` 200, `/health/ready` 503, `POST /orders` 503 + `Retry-After`; recovers automatically |
| hadolint | Clean |
| Trivy (HIGH/CRITICAL, fixable) | 0 findings |
| `terraform fmt` / `validate` (root + bootstrap) | Clean |
| `terraform test` (mocked AWS provider) | 5 passed |
| Checkov | 502 passed, 0 failed, 36 skipped with inline justification |
| actionlint (+ shellcheck) | Clean |

**Not verified:** a real `terraform apply` into an AWS account. The GitHub Actions CI
jobs run green on every push; the AWS build and deploy jobs are gated behind the
`AWS_DEPLOY_ENABLED` repository variable and are skipped until AWS accounts are configured.
The Terraform has been validated, tested offline with a mocked provider and security-scanned.

## Limitations and next steps

- **Authentication / authorization** (JWT via Cognito or an OIDC provider, with
  `customer_id` taken from the token) is the first thing to add before real traffic.
- The app connects as the RDS master user (secret managed and rotated by RDS). Next
  steps: dedicated `orders_app` / `orders_migrator` DB roles, and **IAM authentication to
  RDS Proxy** so tasks hold no password at all. That also removes the "restart tasks
  after rotation" concern ([SECURITY.md §4](SECURITY.md#4-secrets-and-credentials)).
- The outbox → SQS → Lambda pipeline and the scheduled reconciliation job are designed
  and documented but not implemented in this repository.
- ALB → task traffic is plain HTTP inside private subnets (TLS ends at the ALB).
  End-to-end TLS is an option if compliance requires it.
- `sslmode=require` today; move to `verify-full` with the RDS CA bundle in the image.
- GitHub Actions are referenced by major version tag; pin them to commit SHAs (Dependabot
  then keeps the SHAs updated).
- Native ECS blue/green or canary deployments (with a bake time) could replace the rolling
  update for higher-risk releases.
- Regional DR (cross-region snapshot copies or Aurora Global Database) is described but
  not built.
