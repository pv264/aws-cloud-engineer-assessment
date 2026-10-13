# Security

Defence in depth: every layer assumes the one in front of it can fail.

```
Internet ─► WAF (rate limit, managed rules) ─► ALB (TLS 1.3/1.2, ACM)       public subnets
         ─► ECS tasks (non-root, read-only FS, least-privilege role)          private app subnets
         ─► RDS Proxy (TLS) ─► RDS (KMS, TLS forced, no public IP)            isolated data subnets
Around it: IAM least privilege + OIDC CI, Secrets Manager, KMS, CloudTrail, GuardDuty,
           Security Hub, AWS Config, VPC flow logs, CI scanning (Checkov, Trivy, pip-audit, gitleaks)
```

## 1. How an internet user is prevented from reaching the database

Several independent controls, so a single mistake does not expose the data:

| # | Control | Implementation |
|---|---|---|
| 1 | **No public endpoint** | `publicly_accessible = false`: the instance has no public IP and its DNS name resolves only to private addresses |
| 2 | **No route** | The DB lives in *data* subnets whose route table has **no route to an Internet Gateway or NAT**. Even a misconfigured SG would not make it reachable from the internet |
| 3 | **Security group allow-list** | Port 5432 only from the **app** and **RDS Proxy** security groups (SG references, not CIDRs). No `0.0.0.0/0` rule exists or can pass CI. The DB SG has no egress rules |
| 4 | **Only the ALB is public** | The ALB SG accepts 80/443 and can only forward to the app SG on the container port; tasks have no public IPs |
| 5 | **Credentials are not obtainable** | No password exists outside Secrets Manager; only the ECS execution role and RDS Proxy can read it (KMS-encrypted) |
| 6 | **TLS required** | `rds.force_ssl = 1`; RDS Proxy `require_tls = true` |
| 7 | **Guard rails that prevent regressions** | Checkov in CI fails on public RDS (`CKV_AWS_17`) or open SGs; AWS Config managed rules `rds-instance-public-access-check`, `vpc-sg-open-only-to-authorized-ports`; Security Hub FSBP controls (RDS.2); an SCP can deny creating publicly accessible instances |
| 8 | **Verification** | VPC Reachability Analyzer / Network Access Analyzer ("no path from IGW to DB ENIs"); an external connection attempt in the security test plan must fail |

Human access goes through **SSM Session Manager or ECS Exec**. Port forwarding to the
proxy is audited and requires SSO + MFA. There are no bastion hosts and no SSH keys.

## 2. IAM least privilege

| Principal | Can do | Cannot do |
|---|---|---|
| ECS **execution role** (ECS agent) | Pull from ECR, write its log group, read **only** the DB secret (+ `kms:Decrypt` via Secrets Manager) | Anything the application does |
| ECS **task role** (application code) | `s3:GetObject/PutObject` on `assets/orders/*`; ECS Exec channels only if enabled | Read secrets, call other AWS APIs |
| Trust policies | `aws:SourceAccount` / `aws:SourceArn` conditions (confused-deputy protection) | Be assumed by another account's ECS |
| CI **build** role (`gha-ci`) | Push to one ECR repository | Anything in the env accounts |
| CI **plan** role | `ReadOnlyAccess` + state bucket | Change infrastructure |
| CI **deploy** role (per env) | Register task definitions, update **this env's** service, run the migration task, `iam:PassRole` **only** for this env's two task roles **only** to `ecs-tasks.amazonaws.com` | Change IAM, networking, data stores |
| CI **terraform** role (per env) | Apply infrastructure | Be assumed outside the protected GitHub environment (OIDC `sub = repo:<org>/<repo>:environment:<env>`; prod requires reviewers) |
| Humans | IAM Identity Center (SSO + MFA), read-only by default, time-bound elevated access | Use long-lived access keys (none exist) |

- **No long-lived credentials anywhere.** GitHub Actions uses OIDC federation; tasks use
  role credentials from the ECS metadata endpoint.
- **Organisation guard rails:** SCPs (deny leaving the org, disabling CloudTrail/GuardDuty,
  root user actions, regions outside the allow-list) and a **permissions boundary** on roles
  created by Terraform so the admin-level apply role cannot mint a more powerful role.
- **IAM Access Analyzer** for unused access and external access findings.

## 3. Security groups and network

- SG-to-SG references along exactly one path: `alb → app → proxy → db`, plus
  `lambda → proxy` for the legacy/async functions. Rules are separate
  `aws_vpc_security_group_*_rule` resources, so every rule is visible and reviewed.
- The **default security group is emptied**, so nothing can rely on it.
- **Interface VPC endpoints** (ECR, Logs, Secrets Manager, STS, KMS) and an S3 gateway endpoint keep
  AWS API traffic private.
- **VPC flow logs** (all traffic) to an encrypted log group.
- NACLs are left at defaults on purpose: SGs are stateful and reference-based. NACLs
  would be added only for explicit deny-lists.

## 4. Secrets and credentials

**Database credentials**

1. The master password is **generated and rotated by RDS** in Secrets Manager
   (`manage_master_user_password = true`), encrypted with the environment CMK. It is
   never in code, tfvars, the image, CI logs or Terraform state.
2. ECS injects `DB_USER` / `DB_PASSWORD` from the secret's JSON keys **at task start**
   (task definition `secrets`, resolved by the agent with the execution role). The task
   definition only contains the secret **ARN**.
3. The app holds it as a `SecretStr` (never logged or printed in repr).

**Rotation and long-lived connection pools.** Tasks keep the password they started with.
After a rotation, new connections from old tasks fail. There are three options, in increasing order of maturity:

- (a) An EventBridge rule on the rotation event triggers `ecs update-service --force-new-deployment` (rolling restart).
- (b) The app re-reads the secret and retries once on an authentication failure.
- (c) **IAM authentication to RDS Proxy (recommended target).** The task role gets
  `rds-db:connect` and the app uses a short-lived auth token, so the application holds **no
  password at all**.

**Least privilege inside PostgreSQL:** the master user is for break-glass only.
- `orders_app` gets `SELECT/INSERT/UPDATE` on its tables.
- `orders_migrator` gets DDL and is used only by the migration task.
- `orders_readonly` is for analytics.

Each role has its own rotated secret (or IAM auth).

**Application secrets** (API keys for partners, JWT signing keys): stored in Secrets Manager
and injected the same way. Static, non-secret config goes in environment variables (or
SSM Parameter Store).

**Repository hygiene:** `.gitignore` excludes `.env`, tfstate and keys; **gitleaks** runs
in CI over the full history; local development uses a throwaway Postgres whose
default password is a documented, local-only placeholder.

## 5. Encryption

| Data | At rest | In transit |
|---|---|---|
| RDS data, snapshots, automated backups | KMS CMK | TLS forced (`rds.force_ssl`); app `sslmode=require` → `verify-full` with the RDS CA bundle is the next step |
| RDS Proxy | n/a | TLS required client → proxy and proxy → DB |
| Secrets Manager secret | KMS CMK | TLS (VPC endpoint) |
| Performance Insights | KMS CMK | n/a |
| CloudWatch Logs (app, ECS Exec, WAF, VPC flow, RDS) | KMS CMK | TLS |
| SNS alerts topic | KMS CMK | TLS |
| S3 assets | SSE-KMS (bucket key) | TLS-only bucket policy |
| S3 ALB logs | SSE-S3 (ALB log delivery does not support KMS) | TLS-only bucket policy |
| ECR images | KMS | TLS |
| Terraform state | SSE-KMS, versioned | TLS-only |
| Client ↔ ALB | n/a | TLS 1.3/1.2 (`ELBSecurityPolicy-TLS13-1-2-2021-06`), HTTP → 301, HSTS |
| ALB ↔ tasks | n/a | HTTP inside private subnets, restricted by SGs (accepted risk). End-to-end TLS (sidecar or app TLS with a private cert) if compliance requires it |

The CMK has automatic yearly rotation, a 30-day deletion window in prod, and a key policy
that only delegates to IAM and the required AWS services (Logs, CloudWatch→SNS).

## 6. HTTPS and ACM

- Public certificate from **ACM with DNS validation** (records created by Terraform), so
  renewal is automatic.
- Modern TLS policy (TLS 1.3 + 1.2, forward secrecy only). HTTP only redirects.
- **HSTS** (`Strict-Transport-Security: max-age=31536000; includeSubDomains`) and
  `X-Content-Type-Options: nosniff` are added by the ALB HTTPS listener to every response.
- `drop_invalid_header_fields` and `desync_mitigation_mode = defensive` on the ALB
  protect against request smuggling.

## 7. AWS WAF

| Rule | Purpose |
|---|---|
| Rate-based rule (2,000 req / 5 min / IP) | Scraping, brute force, runaway retry loops |
| `AWSManagedRulesAmazonIpReputationList` | Known malicious IPs / botnets |
| `AWSManagedRulesCommonRuleSet` | OWASP Top 10 classes (XSS, LFI, bad bots, size limits) |
| `AWSManagedRulesKnownBadInputsRuleSet` | Log4Shell, Java deserialisation, other exploit patterns |
| `AWSManagedRulesSQLiRuleSet` | SQL injection |

- New or changed rules ship in **COUNT** mode first (`count_only = true`), get reviewed
  in WAF logs for false positives, then switch to BLOCK.
- WAF logs go to CloudWatch (`aws-waf-logs-*`) with the `Authorization` and `Cookie`
  headers **redacted**.
- **Shield Standard** is always on. Shield Advanced (DDoS response team, cost protection) is
  for when the business risk justifies it. Bot Control and account-takeover prevention
  can be added when login endpoints exist.

## 8. S3

- Account-level and bucket-level **Block Public Access**. `BucketOwnerEnforced` (ACLs
  disabled).
- **TLS-only** bucket policy (deny `aws:SecureTransport = false`).
- Default encryption (SSE-KMS with bucket keys for data, SSE-S3 for ALB logs), versioning
  on data buckets, lifecycle tiering and expiry, abort incomplete multipart uploads.
- The app is limited to the `orders/*` prefix of one bucket.
- Public content would be served through **CloudFront with Origin Access Control**, never
  through a public bucket.
- Object-level audit via CloudTrail **S3 data events**. Macie for sensitive-data discovery if
  customer documents are stored.

## 9. Container and image security

| Control | Where |
|---|---|
| Minimal official base (`python:3.13-slim-trixie`) **pinned by digest** | `docker/Dockerfile` |
| Multi-stage build; no compilers, no pip in the runtime image | Dockerfile |
| Dependencies **hash-pinned** (`pip install --require-hashes`) | `app/requirements.txt` |
| Runs as **non-root** UID 10001, code owned by root (not writable) | Dockerfile, task definition `user` |
| **Read-only root filesystem**, writable `/tmp` volume only | Task definition / compose |
| All Linux capabilities dropped; `no-new-privileges` (compose) | Task definition / compose |
| `initProcessEnabled` (proper PID 1, signal handling) | Task definition |
| Dockerfile lint (**hadolint**), image CVE scan (**Trivy**, fails on fixable HIGH/CRITICAL), dependency audit (**pip-audit**) | CI |
| ECR **scan on push** (Amazon Inspector enhanced scanning recommended: continuous re-scan of running images) | ECR |
| **Immutable tags**; deploy by digest; SBOM + SLSA provenance attestations generated at build | ECR, deploy workflow |
| Weekly **Dependabot** updates for pip, Docker base, Actions, Terraform providers | `.github/dependabot.yml` |
| Next: image signing (AWS Signer / cosign) and signature verification at deploy | Roadmap |

## 10. CloudTrail and detection

- **Organisation CloudTrail**: all regions, management events, log-file validation,
  delivered to a dedicated **log-archive account** (S3 with Object Lock, KMS). S3 data
  events for sensitive buckets. CloudTrail Lake or Athena for investigation.
- **GuardDuty** (including ECS runtime monitoring and RDS login activity monitoring),
  **Security Hub** (AWS Foundational Security Best Practices + CIS), **AWS Config**
  (resource history, conformance packs), **IAM Access Analyzer**, **Detective** for
  investigations.
- **Alerts** (EventBridge → SNS / pager): root user sign-in, IAM policy changes,
  CloudTrail/GuardDuty disabled, security group opened to `0.0.0.0/0` on non-web ports,
  KMS key scheduled for deletion, RDS made public, GuardDuty high-severity findings.

## 11. Application security

- Strict input validation (Pydantic, `extra="forbid"`, bounded lengths and amounts,
  patterns for SKU/currency/idempotency key).
- Errors return a uniform envelope with a request id. Stack traces, SQL and input values are
  never echoed. OpenAPI docs are disabled in prod.
- Caller-supplied `X-Request-ID` is accepted only if it matches a safe pattern, which prevents log injection.
- Parameterised queries only (SQLAlchemy). Statement timeout limits the damage of slow queries.
- **Authentication and authorization are out of scope for this exercise** and are the first
  addition before go-live: JWT (Cognito/OIDC) validation middleware, with `customer_id`
  taken from the token instead of the body (prevents IDOR on `GET /orders/{id}`).
- PII minimisation in logs: only ids are logged, never names, addresses or payment data.
