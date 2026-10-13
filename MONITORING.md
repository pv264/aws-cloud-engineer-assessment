# Monitoring and Observability

The alarms, SNS topic, dashboard and log metric filter described here are implemented in
[`terraform/modules/monitoring`](terraform/modules/monitoring/main.tf).

## 1. Principles

- **Page on symptoms users feel** (errors, latency, lost capacity). Use **leading
  indicators** (saturation) for warnings. Every alarm has an owner, a severity and a
  runbook link.
- **SLOs drive alerting:** availability 99.9% (non-5xx) and p99 latency < 500 ms,
  measured at the ALB. Long term, alert on **error-budget burn rate** (multi-window:
  14.4× over 1 h and 6× over 6 h) instead of raw thresholds.
- **Correlate everything with a request id.** The API accepts or creates `X-Request-ID`,
  returns it, and writes it (plus the ALB `X-Amzn-Trace-Id`) on every log line.

## 2. Signals by component

| Component | Metrics (namespace) | Why |
|---|---|---|
| **Application** | Request latency, error rate and volume per route from structured access logs (`duration_ms`, `status`, `route`); `ApplicationErrors` metric filter on `level = ERROR` | What the code sees, per route, including errors that are not 5xx |
| **ALB** | `RequestCount`, `HTTPCode_Target_4XX/5XX_Count`, `HTTPCode_ELB_5XX_Count`, `TargetResponseTime` (p50/p90/p99), `HealthyHostCount` / `UnHealthyHostCount`, `TargetConnectionErrorCount`, `RejectedConnectionCount` (`AWS/ApplicationELB`) | What users see; splits app errors from load-balancer errors |
| **ECS** | `CPUUtilization`, `MemoryUtilization` (`AWS/ECS`); `RunningTaskCount`, `DesiredTaskCount`, task restarts, per-task CPU/memory (`ECS/ContainerInsights`, enhanced mode); container health status | Saturation, crash loops, capacity vs desired |
| **RDS** | `CPUUtilization`, `DatabaseConnections`, `FreeStorageSpace`, `ReadLatency` / `WriteLatency`, `FreeableMemory`, `DiskQueueDepth`, `ReplicaLag` (`AWS/RDS`); Performance Insights / Database Insights (DB load by wait event and top SQL); Enhanced Monitoring (OS) | The usual bottleneck; connections are the leading indicator |
| **RDS Proxy** | `ClientConnections`, `DatabaseConnections`, `DatabaseConnectionsBorrowLatency`, `DatabaseConnectionsCurrentlySessionPinned` | Whether multiplexing is actually working |
| **Lambda** (legacy API during migration, async workers) | `Errors`, `Duration` (p99), `Invocations`, `Throttles`, `ConcurrentExecutions`, `IteratorAge`/SQS `ApproximateAgeOfOldestMessage` for consumers | Failures, slowness, capacity limits, backlog |
| **WAF** | `BlockedRequests`, `AllowedRequests` per rule | Attacks, false positives after rule changes |
| **Business** | Orders created/min, idempotent replays/min, duplicate suspects (reconciliation) | Catches "everything is green but nothing is selling" |

**Logs:** JSON to CloudWatch Logs (KMS-encrypted, retention per environment). Health-check
requests are logged at DEBUG so they don't drown real traffic. Useful Logs Insights queries are in
[MIGRATION_INCIDENT.md](MIGRATION_INCIDENT.md#22-logs-and-queries) and
[INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md#step-6-application-logs). ALB access logs land in S3 and
are queried with Athena.

**Tracing (next step):** the AWS Distro for OpenTelemetry sidecar (or the OTel SDK) exporting
to X-Ray, with 5–10% sampling plus all errors. It shows the time split between app,
proxy and SQL per request.

**Synthetics:** CloudWatch Synthetics canaries every minute, from two regions, run
`/health/ready` plus a read-only order lookup. They catch DNS, certificate and WAF
problems that internal metrics cannot see.

## 3. Production alerts

| # | Alarm | Condition | Severity | Why it matters | First action |
|---|---|---|---|---|---|
| 1 | **`alb-5xx-rate`** | (ELB 5xx + target 5xx) / requests > **2%** in 3 of 5 one-minute periods (ignored below 50 req/min) | Page | Direct measure of failed user requests; covers app errors **and** "no healthy targets". Also rolls back an in-progress ECS deployment | INCIDENT_RESPONSE.md |
| 2 | **`alb-p99-latency`** | `TargetResponseTime` p99 > **1 s** in 3 of 5 minutes | Page | Tail latency is the earliest sign of DB contention or CPU saturation, and turns into timeouts and retries (duplicates). Also rolls back deployments | Check DB waits, ECS CPU |
| 3 | **`unhealthy-targets`** | `UnHealthyHostCount` > 0 for 5 minutes | Page | Lost capacity; a task replace loop after a release shows up here first | describe-target-health, stopped tasks |
| 4 | **`running-tasks-low`** | `RunningTaskCount` < `min_tasks` for 5 minutes | Page | Tasks cannot start or keep crashing (image, secrets, capacity); the service runs below its HA baseline | ECS service events |
| 5 | **`rds-connections-high`** | `DatabaseConnections` > **80%** of `max_connections` | Page | The step right before "too many clients", which would fail every request on both stacks | `pg_stat_activity` by `application_name` |
| 6 | **`rds-cpu-high`** | CPU > 80% for 8 of 10 minutes | Warn | Little headroom left; queries slow down for everyone | Performance Insights top SQL |
| 7 | **`rds-free-storage-low`** | Free storage < 10 GB | Page | A full volume stops all writes; autoscaling may have hit its maximum | Raise `max_allocated_storage` |
| 8 | **`rds-read/writelatency-high`** | > 20 ms for 4 of 5 minutes | Warn | I/O saturation or noisy queries | DiskQueueDepth, IOPS |
| 9 | **`ecs-cpu/memoryutilization-high`** | > 85% for 8 of 10 minutes | Warn | Auto scaling should keep CPU near 60%; sustained 85% means max capacity reached or scaling isn't keeping up | Raise `max_tasks`, check quotas |
| 10 | **`app-error-logs`** | > 20 ERROR lines in 5 minutes | Warn | Failures that don't surface as 5xx (e.g. background steps) | Logs Insights |
| 11 | **`lambda-<fn>-Errors` / `-Throttles`** | Errors > 5/min for 3 of 5 minutes; any throttles | Page during migration, Warn after | The legacy API and async workers silently dropping or delaying work | Lambda logs, concurrency |

**Routing:** alarm → SNS (KMS-encrypted) → PagerDuty/Opsgenie for *Page*, Slack (AWS
Chatbot) for *Warn*. OK notifications close incidents automatically. Composite alarms
(e.g. 5xx-rate AND unhealthy-targets) can reduce noise once the baseline is known.

**Testing alarms:** every alarm is triggered on purpose in staging (fault injection,
`set-alarm-state`) before it is trusted in production.

## 4. Dashboard

The `xyzz-orders-<env>` CloudWatch dashboard (Terraform) shows:
- requests and errors;
- latency p50/p90/p99;
- target health;
- ECS CPU/memory and running vs desired tasks;
- RDS connections/CPU, read/write latency and free storage.

During the migration a second dashboard puts the Lambda and ECS target groups side by side
([MIGRATION.md §11](MIGRATION.md#11-monitoring-during-migration)).
