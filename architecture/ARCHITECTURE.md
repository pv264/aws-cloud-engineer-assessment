# Target Architecture: XYZZ Orders Platform

![Architecture diagram](architecture-diagram.png)

*Source: [`architecture-diagram.svg`](architecture-diagram.svg). The infrastructure in the diagram is defined in [`/terraform`](../terraform).*

## 1. Summary

The order API moves from **API Gateway → Lambda** to a stateless containerized service:

```
Users ─► Route 53 ─► AWS WAF ─► ALB (public subnets, 3 AZs)
      ─► ECS Fargate service (private app subnets, 3 AZs, auto scaling)
      ─► RDS Proxy ─► RDS PostgreSQL Multi-AZ (isolated data subnets)
```

Work that is event-driven, spiky or scheduled **stays serverless** (SQS + Lambda,
EventBridge Scheduler + Lambda, S3 + CloudFront). The goal is to put each workload on
the compute model that fits it. Replacing Lambda with servers everywhere is not the goal.

## 2. Components

| Layer | Service | Configuration | Why |
|---|---|---|---|
| DNS | **Route 53** | Alias A/AAAA → ALB; ACM DNS validation records | Health-aware alias, no TTL management for the ALB IPs, weighted records for the cut-over |
| TLS | **ACM** | DNS-validated certificate, auto-renewed | No certificate expiry incidents |
| Edge security | **AWS WAF** | IP reputation, OWASP core rules, known bad inputs, SQLi, per-IP rate limit, logging with redaction | Blocks common attacks and abusive clients before they cost compute |
| Load balancing | **Application Load Balancer** | HTTPS (TLS 1.3/1.2 policy), HTTP→HTTPS 301, `least_outstanding_requests`, slow start 30s, deregistration 30s, invalid headers dropped, access logs to S3 | L7 routing, health checks, weighted target groups for the migration canary |
| Compute | **ECS on Fargate** (Graviton/ARM64) | 1 vCPU / 2 GB tasks, min 3 / max 30 in prod, spread across 3 AZs, circuit breaker + alarm rollback | No servers to patch, per-task isolation, scales in seconds |
| Connection pooling | **RDS Proxy** | Multiplexes ECS and Lambda connections, TLS required, 80% of `max_connections` | Protects the database from connection storms (ECS pools + Lambda concurrency) and speeds up failover |
| Database | **RDS for PostgreSQL 17** | Multi-AZ, gp3 with storage autoscaling, KMS-encrypted, TLS forced, managed master secret, PITR 14 days, Performance Insights, Enhanced Monitoring | Relational order data with transactions and constraints; managed HA and backups |
| Secrets | **Secrets Manager** | RDS-managed master secret (auto-rotated), injected by the ECS agent | No secret in code, image, tfvars or Terraform state |
| Encryption | **KMS** | One customer-managed key per environment, yearly rotation | Key policy we control, CloudTrail on every use, cross-account snapshot sharing |
| Object storage | **S3** | `assets` (SSE-KMS, versioned, tiered) and `alb-logs` (SSE-S3, expiring); BPA on, TLS-only | Documents/exports and logs. Static content is served from S3 + CloudFront, never from the containers |
| Registry | **ECR** | Immutable tags, scan on push, lifecycle policy | Image provenance; a tag always means the same bytes |
| Observability | **CloudWatch** | Container Insights (enhanced), JSON logs, alarms → SNS, dashboard, metric filters | See [MONITORING.md](../MONITORING.md) |
| Network | **VPC** | 3 tiers × 3 AZs; IGW; NAT gateway per AZ; S3 gateway endpoint; interface endpoints (ECR, Logs, Secrets Manager, STS, KMS); flow logs | Isolation by tier, egress without public IPs, AWS API traffic kept off the NAT |
| Identity | **IAM** | Separate task execution / task roles, GitHub OIDC roles per environment | Least privilege per actor; no long-lived keys. See [SECURITY.md](../SECURITY.md) |

### Network layout (per environment, /16)

| Tier | Subnets | Route to internet | Contains |
|---|---|---|---|
| Public | 3 × /24 | Internet Gateway | ALB, NAT gateways |
| Private app | 3 × /20 (4,091 IPs each) | NAT gateway in the same AZ | ECS tasks, VPC-attached Lambdas, interface endpoints |
| Private data | 3 × /24 | **None** | RDS primary + standby, RDS Proxy |

The app tier is sized generously because every Fargate task consumes one IP address.
With 10× growth, IP exhaustion is a real outage cause.

## 3. Design questions

### 3.1 Why ECS on Fargate (and not EC2, or both)?

**I chose ECS on Fargate.** The API is a stateless HTTP container, and Fargate removes
the whole host layer:

| Concern | ECS on Fargate | EC2 (ASG or ECS on EC2) |
|---|---|---|
| OS patching, AMI pipeline, agent upgrades | None (AWS) | Ours |
| Capacity management / bin packing | Per task, nothing to over-provision | Cluster capacity + capacity providers |
| Isolation | Each task in its own micro-VM | Tasks share a kernel per host |
| Scaling speed | Tasks in ~30–60s | New instance first (minutes) unless warm pools |
| Deploy safety | Rolling + circuit breaker + alarm rollback built in | Same on ECS-on-EC2; DIY on raw EC2 |
| Cost at low/medium utilization | Pay per task-second | Pay for idle instance headroom |
| Cost at very high steady utilization | ~10–20% premium per vCPU | Cheaper with RIs/Savings Plans and dense packing |

**When I would add EC2:** ECS on EC2 (as an extra capacity provider) only if the
service settles at high, steady utilization where bin-packed Graviton instances with
Savings Plans beat Fargate. Raw EC2 makes sense for workloads Fargate cannot run
(GPU, custom kernels, privileged daemons, large local disks). None of these apply to an order API.

**Why not EKS:** Kubernetes would add a control plane, upgrades and add-ons to run, plus
a skill requirement, and buy nothing this service needs. ECS integrates natively with ALB, IAM
and CloudWatch, with far less to operate.

**Why move off Lambda for this API at all** (it was a business decision, but these are
the technical reasons that make it sound):

- Every concurrent invocation opens its own DB connection. Spikes become connection storms.
- Cold starts show up in p99 latency.
- At sustained high throughput, per-request pricing costs more than right-sized
  containers.
- Connection pools, keep-alive and in-process caches survive between requests.

### 3.2 High availability

- **Three Availability Zones** for every tier: ALB nodes, ECS tasks, NAT gateways (one
  per AZ, so an AZ failure cannot take egress away from the others), RDS Multi-AZ and RDS Proxy.
- **ECS:** `min_tasks = 3` (≥ number of AZs). The service spreads tasks across AZs and
  `availability_zone_rebalancing` restores the spread after an AZ recovers. Losing an AZ
  leaves ⅔ of capacity immediately, and auto scaling replaces the rest.
- **RDS Multi-AZ:** a synchronous standby in another AZ with automatic failover
  (typically 60–120 s). RDS Proxy keeps client connections open and reconnects to the new
  primary, so clients see a pause instead of a flood of connection errors.
- **Stateless tasks:** no local state. Any task can serve any request, and losing one only drops its in-flight requests.
- **Health checks at three levels:**
  1. The container health check restarts a hung process.
  2. The ALB target health check stops routing to a bad task.
  3. ECS replaces unhealthy tasks.
  
  The ALB checks the **shallow** `/health` endpoint on purpose. If it checked the
  database, a DB blip would mark every task unhealthy at once and turn a partial
  degradation into a full 503 outage. The deep check (`/health/ready`) is used by smoke tests and synthetic canaries.
- **Data durability:** automated backups with point-in-time recovery (14 days in prod),
  deletion protection, final snapshot on delete, KMS-encrypted snapshots (can be copied
  to another region or account for DR).

**Targets:** 99.9% availability SLO; RPO ≈ 0 for an AZ failure (synchronous standby),
≤ 5 min for a logical error (PITR); RTO ≈ 2 min for an AZ failure. Regional DR is
discussed in [SCALABILITY.md](../SCALABILITY.md#7-high-availability-and-disaster-recovery).

### 3.3 How traffic is distributed

1. **Route 53** alias record → ALB (health-evaluated).
2. **WAF** evaluates every request (rate limit first, then managed rules).
3. The **ALB** terminates TLS (ACM). The HTTPS listener forwards to the ECS target group;
   HTTP returns a 301 redirect to HTTPS.
4. The **target group** (`ip` targets = Fargate task ENIs) uses
   **least outstanding requests** rather than round robin, so a task that is slow
   (GC, a slow query) gets fewer new requests. Cross-zone load balancing is on (ALB default), so
   uneven task counts per AZ do not unbalance load. New tasks get a 30 s **slow start**.
5. **During the migration** the same listener forwards to **two weighted target groups**:
   the legacy Lambda (Lambda is a native ALB target) and ECS. Weights shift traffic per
   request, instantly, with no DNS caching ([MIGRATION.md](../MIGRATION.md)).

Timeouts line up so that each layer gives up after the one in front of it, which avoids
502 races:

| Layer | Setting | Value |
|---|---|---|
| Client | Request timeout | ≥ 10 s, with retries + `Idempotency-Key` |
| ALB | Idle timeout | 60 s |
| App | Keep-alive timeout | 75 s (> ALB idle timeout) |
| App → DB | Pool wait / connect / statement timeout | 3 s / 5 s / 5 s (fail fast with 503 + `Retry-After`) |
| ALB → ECS | Deregistration delay | 30 s |
| ECS | `stopTimeout` (SIGTERM → SIGKILL) | 30 s; Uvicorn graceful shutdown 25 s |

### 3.4 How the application scales

- **Horizontally, automatically:** ECS Service Auto Scaling with two target-tracking
  policies, **CPU at 60%** and **ALB requests per target** (6,000/min ≈ 100 RPS per
  task, about ⅔ of a task's measured capacity). Whichever asks for more tasks wins. Scale-out cooldown is 60 s and scale-in is 300 s
  (out fast, in slowly).
- **Capacity mix:** a base of on-demand Fargate tasks plus Fargate Spot above the base
  (prod 3:1 on-demand:Spot; dev 100% Spot).
- **Database:** connection multiplexing through RDS Proxy, vertical scaling, read
  replicas for read-heavy endpoints, storage autoscaling. Beyond that, Aurora PostgreSQL. See
  [SCALABILITY.md](../SCALABILITY.md).
- **Per task:** 2 Uvicorn worker processes per vCPU-task, each with a bounded
  SQLAlchemy pool (5 + 5 overflow). The connection budget is explicit:
  `max_tasks × workers × (pool + overflow)` must fit behind the proxy.

### 3.5 How the database is secured

| Control | Implementation |
|---|---|
| Not reachable from the internet | `publicly_accessible = false`; data subnets have **no route** to an IGW or NAT |
| Network allow-list | DB security group accepts 5432 **only** from the app and RDS Proxy security groups (SG-to-SG references, no CIDRs); Lambdas reach it only through the proxy |
| Credentials | Master password generated and rotated by RDS in Secrets Manager (`manage_master_user_password`), never in code, tfvars or state; ECS injects it at task start |
| Encryption at rest | Storage, snapshots, Performance Insights and the secret use the environment CMK |
| Encryption in transit | `rds.force_ssl = 1`; app uses `sslmode=require` (`verify-full` with the RDS CA bundle is the next step); RDS Proxy `require_tls` |
| Least privilege inside the DB | Recommended: an `orders_app` role (DML only) and an `orders_migrator` role (DDL), with the master user kept for break-glass ([SECURITY.md](../SECURITY.md)) |
| Hygiene | `idle_in_transaction_session_timeout`, slow-query and lock-wait logging, IAM DB auth enabled, deletion protection, PITR, logs exported to CloudWatch |

### 3.6 How failures are handled

| Failure | Detection | Automatic response | User impact |
|---|---|---|---|
| App process hangs | Container health check | ECS restarts the task | Requests on that task fail / are retried |
| Task unhealthy | ALB health check (3 × 10 s) | Removed from rotation; ECS replaces it | None (other tasks serve) |
| Bad deployment (crash loop) | Deployment circuit breaker | Automatic rollback to last good revision | None: old tasks keep serving (min healthy 100%) |
| Bad deployment (5xx / latency) | `alb-5xx-rate`, `alb-p99-latency` alarms | ECS deployment rollback; pipeline smoke test also rolls back | Limited to the bake window |
| AZ outage | ALB / ECS / RDS health | ALB stops using the AZ; ECS reschedules into healthy AZs; RDS fails over; NAT per AZ keeps egress | Brief elevated latency; ⅔ capacity until replaced |
| DB failover / restart | RDS events, connection errors | Proxy holds client connections; `pool_pre_ping` drops dead connections; app returns **503 + Retry-After** quickly instead of hanging | 60–120 s of retries for writes; idempotency makes retries safe |
| DB saturated / pool exhausted | Pool timeout (3 s), RDS alarms | Fail fast with 503 rather than queueing; auto scaling must **not** add connections (proxy caps them) | Partial errors instead of a total outage |
| Fargate Spot interruption | 2-minute SIGTERM notice | Graceful drain; replaced on demand | None |
| Traffic spike | Request-count scaling, WAF rate limit | Scale out; abusive clients throttled | Possible brief latency increase |
| Region outage | Route 53 health checks | Manual DR runbook (see SCALABILITY.md) | RTO in hours (business-accepted) |

### 3.7 Supporting significant traffic growth (5k → 50k+ concurrent users)

Short version (details and capacity math in [SCALABILITY.md](../SCALABILITY.md)):

- Stateless containers scale horizontally. Raise `max_tasks` and the Fargate vCPU quota, and pre-scale for known events.
- The database is the real limit. In order:
  1. Connection multiplexing (proxy)
  2. Query and index tuning
  3. Vertical scaling
  4. Read replicas for reads
  5. A cache for hot reads
  6. Aurora PostgreSQL (more replicas, faster failover)
  7. Partitioning, if order volume requires it
- Move non-critical work out of the request path (SQS + workers). Serve static and cacheable content from CloudFront.

### 3.8 What stays serverless, and why

| Workload | Service | Why serverless fits |
|---|---|---|
| Order side effects: confirmation e-mail, invoice PDF, partner webhooks | **SQS → Lambda** (DLQ, partial batch failures, reserved concurrency) | Spiky and asynchronous; it must not slow the API; retries and DLQ come for free; pay per event. The API writes an outbox row in the order transaction, and a relay publishes it to SQS, so no event is lost if SQS is briefly unavailable |
| Scheduled jobs: purge expired idempotency keys, nightly reconciliation, reports | **EventBridge Scheduler → Lambda** | Runs minutes per day; a server would sit idle |
| File processing: bulk order imports dropped in S3 | **S3 event → Lambda** (or Step Functions for multi-step) | Event-driven, bursty, short |
| Static content / front-end assets | **S3 + CloudFront** | No compute at all |
| Secret rotation | Managed by RDS / Secrets Manager | Fully managed |

The synchronous, steady, connection-heavy order API is what moves to ECS.
