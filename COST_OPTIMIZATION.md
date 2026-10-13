# AWS Cost Optimization

**Rule:** reduce waste, not resilience. Production keeps Multi-AZ, ≥ 3 tasks across 3 AZs, backups and alarms.
Every change is tried in staging first and watched against the SLOs afterwards.

## 1. Find where the money goes

1. **Allocation:** every resource carries `Project`, `Environment`, `CostCenter` and
   `ManagedBy` tags (Terraform `default_tags`), activated as cost allocation tags.
   **Tag policies** enforce them. Separate accounts per environment make the split
   unambiguous.
2. **Explore:** Cost Explorer grouped by service → usage type → tag. The **CUR 2.0**
   export in Athena answers line-item questions such as "which NAT gateway processes the
   most GB, and from which subnet?".
3. **Recommendations:** Compute Optimizer (Fargate task sizes, RDS instance size),
   Trusted Advisor (idle and unused resources), Savings Plans / RI recommendations.
4. **Guard rails:** AWS Budgets per account with alerts at 80% and 100% of forecast, and
   **Cost Anomaly Detection** per service, alerting the team channel.
5. **Unit economics:** track **cost per 1,000 orders**. Total cost can rise with
   growth while unit cost falls, which is healthy.

## 2. Indicative production baseline (us-east-1, on-demand list prices, approximate)

| Item | Sizing | ≈ $/month |
|---|---|---|
| RDS PostgreSQL `db.r7g.large` Multi-AZ + 100 GB gp3 | 2 × instance | ~375 |
| ECS Fargate ARM64, 1 vCPU / 2 GB, ~6 tasks average | ~$29 per task-month | ~175 |
| NAT gateways | 3 × hourly + data processing | ~100 + $0.045/GB |
| Interface VPC endpoints | 6 services × 3 AZs | ~130 |
| ALB | hourly + LCUs | ~40 |
| RDS Proxy | per DB vCPU | ~22 |
| WAF | ACL + 5 rules + requests | ~15 |
| CloudWatch (logs, metrics, alarms, dashboard), KMS, Secrets Manager, S3, ECR | | ~60–120 |
| **Total** | | **~ $950–1,000** |

*Use the AWS Pricing Calculator for real numbers.* The table is there to show **where
the levers are**: the database and the network are as large as compute.

## 3. Recommendations

| # | Recommendation | Expected saving | Effort | Risk |
|---|---|---|---|---|
| 1 | **Right-size ECS tasks and tune auto scaling.** Use Container Insights to size tasks to the p95 of real usage (e.g. 1 vCPU / 2 GB → 0.5 vCPU / 1 GB if memory stays < 40%). Target 60% CPU, scale in after 5 minutes, scheduled scale-down at night | 20–40% of Fargate | Low | Low; validate with a load test |
| 2 | **Graviton everywhere.** ARM64 Fargate (already default) and `r7g`/`t4g` RDS | ~20% on compute and DB | Low (multi-arch image already built) | Low |
| 3 | **Commit to the baseline.** A Compute Savings Plan for the always-on Fargate baseline (also covers Lambda), and RDS Reserved Instances (1-year, no upfront) for the prod database once its size is stable | ~20–30% Fargate, ~30–40% RDS | Low | Commitment; size it to the minimum, not the peak |
| 4 | **Cut NAT gateway costs.** Look at NAT `BytesOutToDestination` in CUR; keep AWS API traffic off NAT (S3 gateway endpoint is free; interface endpoints for ECR/Logs/Secrets pay off once that traffic exceeds ~150–200 GB/month per service); single NAT in dev/staging (already); keep traffic in-AZ | 30–70% of NAT spend | Low–Medium | Single NAT is an AZ-level SPOF, so non-prod only |
| 5 | **Right-size RDS and turn off what isn't used.** Downsize via Performance Insights (CPU < 30%, low memory pressure); no Multi-AZ, smaller class and 1-day backups in dev (already); stop dev/staging databases outside working hours (or Aurora Serverless v2 scaling down); gp3 instead of io1/io2 unless IOPS demand it; delete manual snapshots past retention | 30–60% of non-prod DB | Medium | Low (non-prod) |
| 6 | **Fargate Spot** for dev/staging (100%) and the burst part of prod (3:1 on-demand:Spot above the base) | Up to 70% on Spot capacity | Low (configured) | Interruptions: graceful drain handles them |
| 7 | **Log retention and volume.** Never "never expire" (retention set on every log group); INFO in prod; health checks at DEBUG (already); **Infrequent Access** log class for audit-style logs; archive to S3 Glacier via subscription; sample high-volume access logs | 30–60% of CloudWatch Logs | Low | Low |
| 8 | **S3 lifecycle.** Assets → Standard-IA after 30 days → Glacier IR after 90 (implemented); expire ALB logs (implemented); expire non-current versions; abort incomplete multipart uploads (implemented); Intelligent-Tiering where access patterns are unknown | 40–70% of S3 storage | Low | Low |
| 9 | **CloudFront** in front of S3 and cacheable API GETs: lower data-transfer-out price than direct from the ALB/region, free origin fetches from AWS origins, fewer ALB LCUs and fewer tasks | Egress + compute, grows with traffic | Medium | Cache-key correctness |
| 10 | **Remove unused resources.** Idle ALBs, unattached EIPs and public IPv4 addresses (charged hourly), old ECR images (lifecycle policy in place), orphaned snapshots/volumes, unused interface endpoints, stale Lambda provisioned concurrency, and **the legacy API Gateway + Lambda after the migration**. Run Trusted Advisor / Config rules weekly; delete only after 7 days of zero use | Varies; often 5–15% of total | Low | Low with the 7-day rule |
| 11 | **Architecture choices.** Keep spiky/async work on Lambda + SQS (pay per use instead of idle containers); cache hot reads (one cache node is cheaper than scaling the DB); avoid cross-AZ chatter; schedule non-prod environments to zero outside working hours (~65% of non-prod compute) | Structural | Medium | Low |

## 4. Process

- **Monthly cost review** with engineering and finance: top movers, anomalies, unit cost
  trend, open recommendations.
- **Cost in code review:** Terraform plans for new NAT gateways, endpoints, instance class
  changes and log retention get a cost note (Infracost in CI is a cheap addition).
- **Ownership:** each cost-center tag has an owner who receives the budget alerts.
