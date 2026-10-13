# Terraform

Infrastructure for the Orders platform. One root module (this directory) describes a
complete environment; `environments/<env>.tfvars` and `environments/<env>.s3.tfbackend`
select which one.

```
terraform/
├── versions.tf / providers.tf   Terraform >= 1.11, AWS provider ~> 6.0, default tags, account guard
├── main.tf                      Composition of the modules below
├── variables.tf / outputs.tf
├── environments/                dev | staging | prod: *.tfvars + *.s3.tfbackend
├── modules/
│   ├── network/          VPC, 3-tier subnets, IGW, NAT per AZ, route tables, endpoints, flow logs
│   ├── security_groups/  alb → app → proxy → db chain (+ lambda)
│   ├── kms/              Environment CMK (rotation, service grants)
│   ├── s3_bucket/        Private, encrypted, TLS-only bucket with lifecycle
│   ├── certificate/      ACM certificate + Route 53 DNS validation
│   ├── alb/              ALB, target group(s), listeners, migration weights, canary rule
│   ├── waf/              WAFv2 web ACL, managed rules, rate limit, logging
│   ├── ecs_service/      Cluster, IAM roles, task definition, service, auto scaling
│   ├── rds/              PostgreSQL Multi-AZ, parameters, monitoring, RDS Proxy
│   └── monitoring/       SNS, alarms, log metric filter, dashboard
├── bootstrap/            One-off per account: state bucket, ECR, GitHub OIDC roles
└── tests/                `terraform test` with a mocked AWS provider
```

## Usage

```bash
# 0. Once per AWS account (admin credentials, local state)
cd terraform/bootstrap
terraform init && terraform apply -var github_owner=<org>

# 1. Each environment
cd terraform
terraform init -reconfigure -backend-config=environments/dev.s3.tfbackend
terraform plan  -var-file=environments/dev.tfvars \
                -var container_image=<account>.dkr.ecr.us-east-1.amazonaws.com/xyzz-orders-api:<git-sha> \
                -out=tfplan
terraform apply tfplan

# Offline checks (no AWS credentials needed)
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test
```

In normal operation nobody runs `apply` by hand. The pipeline does it
([`deploy-environment.yml`](../.github/workflows/deploy-environment.yml)).

## Terraform state

- **Remote state in S3**, one bucket per account created by `bootstrap/`:
  - versioned, so every state revision can be restored;
  - SSE-KMS with its own key;
  - Block Public Access and TLS-only policy;
  - old versions expire after 90 days, keeping the last 50.
- **One state file per environment** (`orders-platform/<env>/terraform.tfstate`), and
  ideally one AWS account per environment. A mistake in dev cannot touch prod state,
  and the blast radius of any apply is one environment.
- **Access:** only the CI roles and a break-glass admin group can read or write state.
  State is treated as sensitive even though this design keeps secrets out of it.
- **Recovery:** restore a previous object version; `terraform state` surgery only through a
  reviewed pull request with a backup taken first.

## State locking

`use_lockfile = true` uses **S3 native locking** (a conditional-write `.tflock` object
next to the state), available since Terraform 1.10 and GA in 1.11. It replaces the
DynamoDB lock table, which is now deprecated. Two concurrent applies cannot both get the
lock, and CI uses `-lock-timeout=5m` to wait rather than fail. A stuck lock is released
with `terraform force-unlock <id>` only after confirming that no run is active.

On top of that, the deploy workflow has `concurrency: deploy` (never two deployments at once).

## Secrets

- **No secrets in Terraform code, tfvars or state.**
  - The RDS master password is created and rotated by RDS in Secrets Manager
    (`manage_master_user_password`). Terraform only references the secret **ARN**.
  - ECS resolves the value at task start.
- No AWS credentials anywhere: CI authenticates with GitHub OIDC, humans with IAM
  Identity Center.
- Values that are sensitive but not secrets (account ids, hosted zone ids) live in
  tfvars. Anything truly secret that Terraform must pass on would come from Secrets
  Manager / SSM data sources at plan time and be marked `sensitive`. Ephemeral
  resources and write-only arguments (Terraform ≥ 1.11) keep such values out of state.
- `.gitignore` excludes `*.tfstate`, `*.tfplan`, `.terraform/` and `.terraformrc`;
  gitleaks runs in CI.

## Development / staging / production

| | dev | staging | prod |
|---|---|---|---|
| AWS account | dev | staging | prod |
| AZs / NAT | 2 / single NAT | 3 / single NAT | 3 / NAT per AZ |
| ECS | 0.5 vCPU, 1–3 tasks, 100% Spot | 1 vCPU, 2–6 tasks, 50% Spot above base | 1 vCPU, 3–30 tasks, base on-demand |
| RDS | `db.t4g.micro`, single-AZ, no proxy, 1-day backups | `db.t4g.medium`, Multi-AZ, proxy | `db.r7g.large`, Multi-AZ, proxy, 14-day PITR, deletion protection |
| Domain / TLS | ALB DNS name, HTTP | HTTPS | HTTPS |
| Logs | 14 days | 30 days | 90 days |

- **Same code, different inputs.** Environments differ only in tfvars, so staging
  really tests what prod will run. No per-environment copies of modules, and no
  Terraform workspaces (separate backends and accounts are more explicit and safer).
- `allowed_account_ids` makes the provider refuse to run against the wrong account.
- Variable **validations** (environment name, CIDR size, AZ list, traffic weight) fail
  early, and `terraform test` exercises dev, prod and the migration settings offline.

## Production infrastructure changes

1. **Pull request.** CI runs fmt, validate, `terraform test`, TFLint and Checkov, and
   the PR shows a `plan` for each environment. Review focuses on resource
   **replacements/destroys** (`-/+`, `-`), IAM and network changes.
2. **Merge to main.** The pipeline plans and applies dev, then staging. Smoke tests must
   pass in each.
3. **Prod.** A plan is produced and saved. A reviewer approves the GitHub `prod`
   environment after reading **that** plan in the job summary. The job applies exactly
   the saved plan file; if anything changed since, apply refuses (stale plan).
4. **Risky changes** (DB class, engine upgrade, parameter changes needing a reboot,
   subnet/VPC changes): scheduled in the maintenance window, rehearsed in staging,
   `apply_immediately = false` for RDS, a snapshot first, a written rollback plan. Data
   stores have `deletion_protection` and `prevent_destroy` where losing them would be
   unrecoverable.
5. **Drift:** a scheduled plan (daily) alerts on any drift from manual changes. The
   console is read-only for humans in prod.
6. **Emergency changes** (e.g. setting the migration traffic weight back in an incident)
   can be made with the CLI, but they are recorded in the incident and back-ported to code
   within the day, so the next apply doesn't revert them.

## Design notes

- **The ECS service ignores `task_definition` and `desired_count`.** Releases are
  rolled out by CI (new revision with the new image) and capacity is owned by auto
  scaling. Terraform still owns everything else in the task definition (env vars,
  secrets, CPU/memory, roles, logging), and CI always starts from the latest revision
  of the family.
- **Plan-time knowable `count`s:** conditions use static inputs
  (`enable_https`, `length(var.secrets)`, an `assets_bucket` object) rather than
  `arn != null` of resources created in the same run. Otherwise the very first plan
  of a new environment fails with "count depends on values known only after apply".
  The offline tests found two such bugs.
- **Explicit AZ list:** a data-source lookup could change under you, for example if an AZ
  were reported impaired, and re-index every subnet.
- **Checkov:** 0 failed checks. 36 skips, each justified inline (`#checkov:skip=...:reason`)
  next to the resource it applies to.
