# Scalability and High Availability: 5,000 → 50,000+ concurrent users

## 1. Capacity model

"Concurrent users" has to be turned into request rates before anything can be sized.
Assumptions (to be replaced by production telemetry and confirmed by load tests):

| Input | Value |
|---|---|
| Requests per active user | 1 every ~10 s (think time) |
| Read / write mix | 80% `GET` / 20% `POST /orders` |
| Peak-to-average | 2× |
| Target latency | p99 < 300 ms reads, < 800 ms writes |
| Measured throughput per task (1 vCPU / 2 GB, 2 Uvicorn workers) | **~150 RPS** at 60% CPU (to be validated by load test) |

| | Today (5k users) | Target (50k users) |
|---|---|---|
| Average RPS | 500 | 5,000 |
| Peak RPS | 1,000 | 10,000 |
| Write RPS (peak) | 200 | 2,000 |
| ECS tasks at peak (150 RPS each) | ~7 | **~67** |
| `max_tasks` (headroom) | 30 | **100** |
| Fargate vCPU needed at max | 30 | 100 → **raise the Fargate On-Demand vCPU quota** |
| App-side connections at max (2 workers × 10) | 600 | 2,000 → **must go through RDS Proxy** |

The table shows that **compute scales almost linearly and cheaply; the database does
not**, so most of this document is about the database and keeping work off it.

## 2. Application compute

| What | How | Why |
|---|---|---|
| **ECS Service Auto Scaling** | Target tracking on CPU (60%) **and** ALB requests per target (6,000/min ≈ 100 RPS); scale out 60 s, scale in 300 s | Two signals cover CPU-bound and I/O-bound load |
| Scheduled scaling | Raise `min_capacity` ahead of known peaks (sales, campaigns) | Target tracking reacts in minutes; peaks are known in advance |
| Fast, cheap tasks | Slim image (~90 MB of dependencies), lazy DB connection, ~5 s startup; 30 s slow start | Scale-out speed is bounded by image pull + start time |
| Graviton (ARM64) | `cpu_architecture = "ARM64"` | ~20% cheaper per vCPU-hour, same performance or better |
| Capacity providers | Base on Fargate on-demand, burst partly on Fargate Spot | Cheaper burst capacity with graceful interruption handling |
| Quotas | Fargate vCPU quota, ENIs per VPC, ALB targets per TG (1,000), task launch rate | Quotas cause scaling failures at 10×; request increases before the event |
| Later, if utilization is steady and high | ECS on EC2 (Graviton) capacity provider + Savings Plans | Cheaper at very high, steady utilization |

## 3. Load balancing

- The **ALB scales automatically**. For known step-changes (launch events), use ALB
  **LCU capacity reservation** so it doesn't have to scale up under the spike.
- `least_outstanding_requests` + cross-zone load balancing + slow start keep load even as
  tasks come and go.
- HTTP keep-alive between ALB and tasks (75 s app keep-alive) avoids connection churn.
- WAF scales with the ALB. Rate limits protect the backend from a single noisy client.
- **CloudFront in front of the ALB** at this scale: TLS at the edge, Shield at the edge,
  caching of cacheable GETs, and (with CloudFront VPC origins) the ALB can become
  **internal**, so the origin has no public surface.

## 4. Database

The database is the scaling bottleneck. Steps in order of cost and complexity:

1. **Connection management first.** RDS Proxy multiplexes thousands of client
   connections onto a bounded pool (80% of `max_connections`). The budget is explicit:
   `max_tasks × workers × (pool + overflow) + Lambda reserved concurrency + ops`.
   Avoid session pinning (no per-connection `SET`/startup options; move
   `statement_timeout` to the DB role).
2. **Query efficiency.** `pg_stat_statements` + Performance Insights top SQL; indexes
   for every access path (`orders.customer_id`, `order_items.order_id` already exist);
   avoid N+1 (items loaded with `selectin`); keep transactions short.
3. **Vertical scaling.** `db.r7g.large` → `xlarge` → `2xlarge` (Multi-AZ modifications
   fail over to the upgraded standby; brief blip). Usually enough for 2,000 writes/s on this
   schema.
4. **RDS read replicas for reads.** `GET /orders/{id}` and reporting go to replicas
   via a reader endpoint (separate engine/session in the app).
   **Replica lag**: a client that just created an order must read its own write. Route
   reads from the same client to the primary for a few seconds after a write, or serve
   them from the cache populated on write.
5. **Cache hot reads** (ElastiCache, §5) to cut read load before adding replicas.
6. **Aurora PostgreSQL** when one instance plus replicas is not enough: up to 15
   low-lag replicas, storage that grows automatically, faster failover (~30 s), I/O-Optimized pricing for
   I/O-heavy loads, Aurora Serverless v2 for spiky dev/test. Aurora Global Database if
   cross-region DR with RPO < 1 s is required.
7. **Partition `orders` by time** (monthly) when the table reaches hundreds of millions
   of rows: smaller indexes, cheap archival of old partitions.
8. **Move non-relational, high-churn data out**: e.g. idempotency keys with a TTL or
   rate-limit counters in DynamoDB/ElastiCache if they become a hotspot.

Storage auto scaling (`max_allocated_storage`) and gp3 IOPS/throughput provisioning
cover storage growth.

## 5. Caching

| Cache | Use | Pattern |
|---|---|---|
| **ElastiCache (Valkey), cluster mode, Multi-AZ** | `GET /orders/{id}` (immutable after confirmation), product/price lookups, rate-limit counters, idempotency fast path | Cache-aside, short TTL (30–300 s), invalidate on update, cache only committed data |
| **CloudFront** | Static assets; public, cacheable `GET`s (catalogue, config) | Cache keys and TTLs per path; never cache personalised order data without auth-aware keys |
| In-process (per worker) | Small, immutable reference data | Bounded LRU with TTL |

During the migration no order data is cached (see [MIGRATION.md](MIGRATION.md#54-data-consistency)).

## 6. Static content, background processing, network, monitoring

**Static content:** S3 + CloudFront (Origin Access Control, Brotli/gzip, long TTLs
with versioned file names). The containers never serve files.

**Background processing:**

```
POST /orders ─► INSERT order + INSERT outbox_event (same transaction) ─► 201
outbox relay ─► SQS (orders-events) ─► Lambda / ECS worker ─► email, invoice PDF, partner webhook
                                   └─► DLQ (alarm on depth)
```

- **SQS** absorbs bursts and decouples slow side effects from request latency.
- The **outbox** guarantees an event for every committed order (no dual-write between
  DB and queue).
- **Lambda consumers** for spiky, short work (reserved concurrency caps DB/partner
  pressure); an **ECS worker service** scaled on `ApproximateNumberOfMessagesVisible` /
  age of oldest message for long-running or high-volume work.
- Consumers are idempotent (dedupe on event id), with partial batch failure reporting and DLQs with redrive.

**Network:**

- App subnets are /20 per AZ (~4,000 IPs each): 100+ tasks plus Lambda ENIs fit easily.
- One NAT gateway per AZ (no cross-AZ data charges, no shared failure); NAT gateways
  scale to 100 Gbps.
- VPC endpoints keep ECR/Logs/Secrets traffic off NAT.
- Watch cross-AZ data transfer (task → proxy → DB in different AZs), ENI and security-group
  rule quotas.

**Monitoring at scale:** SLO-based alerting (burn rates) instead of static thresholds,
Embedded Metric Format for high-cardinality business metrics, ADOT/X-Ray tracing with
sampling, CloudWatch Contributor Insights for top clients/routes, log sampling
for high-volume access logs. Details in [MONITORING.md](MONITORING.md).

## 7. High availability and disaster recovery

| Scenario | Design | RTO / RPO |
|---|---|---|
| Task / host failure | Stateless tasks, ALB health checks, ECS replacement | Seconds / 0 |
| AZ failure | 3 AZs; ≥ 3 tasks; RDS Multi-AZ; NAT per AZ; proxy multi-AZ | ~2 min / 0 |
| Bad deployment | Circuit breaker + alarm rollback; previous image retained | Minutes / 0 |
| Logical data corruption | PITR (14 days), snapshots | ~1 h / ≤ 5 min |
| Region failure | **Warm standby / pilot light:** snapshots + Secrets copied cross-region (or Aurora Global Database), ECR replication, same Terraform with a second region's tfvars, Route 53 failover records | Hours / ≤ 15 min (snapshot copy) or ≤ 1 s (Aurora Global) |

The DR tier is a business decision: cost of standby vs cost of downtime. It is tested
with a game day at least twice a year.

## 8. Where each service fits

| Service | Use it for | Where in the architecture | Why |
|---|---|---|---|
| **Auto Scaling** | ECS service (CPU + request count + scheduled), RDS storage, DynamoDB/Aurora replicas if used | Compute and data tiers | Capacity follows demand; pay for what's used |
| **ECS (Fargate)** | The synchronous order API; long-running/high-volume queue workers | Private app subnets behind the ALB | Stateless containers, fast horizontal scaling, no hosts |
| **RDS Read Replicas** | Read-heavy endpoints, reporting/analytics queries | Data tier, reader endpoint | Offload reads from the primary; mind replica lag |
| **ElastiCache** | Hot reads, rate limits, idempotency fast path | Between app and DB (private subnets) | Sub-ms reads; protects the database |
| **SQS** | Order side effects, partner webhooks, bulk imports | Between API and workers | Buffers bursts, retries, DLQ, decoupling |
| **Lambda** | SQS consumers for spiky async work, schedules, S3 events | Async tier | Scales to zero, per-event pricing, no idle capacity |
| **CloudFront** | Static content, cacheable GETs, edge TLS/WAF/Shield, private ALB origin | In front of S3 and the ALB | Lower latency and egress cost; protects the origin |

## 9. Proving it: load and resilience testing

- **Load tests** (k6 / Distributed Load Testing on AWS) on prod-sized staging: ramp to
  1×, 2×, 10× today's peak; soak 4 h; spike test (0 → peak in 60 s).
- **Pass criteria:** p99 within SLO, error rate < 0.1%, auto scaling keeps CPU < 75%,
  DB connections < 60% of max, no throttling (Fargate, ALB, DB).
- **Resilience tests** under load: kill tasks, RDS failover reboot, block an AZ
  (AWS Fault Injection Service), Spot interruption, secret rotation.
- **Quota review** before every 2× growth step.
