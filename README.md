# DevOps Assignment — Octa Byte AI

End-to-end DevOps for a small **Notes** application (Node.js + Express + PostgreSQL) on AWS.

| Layer | Choice |
| --- | --- |
| IaC | Terraform, remote state in S3 with DynamoDB locking |
| Compute | ECS Fargate in private subnets |
| Database | RDS PostgreSQL in private subnets, Multi-AZ toggle |
| Edge | Application Load Balancer |
| Secrets | **AWS Secrets Manager**, injected into the task at start |
| Backups | RDS automated backups, PITR, final snapshot |
| CI/CD | GitHub Actions: tests → scan → build → staging → gated production |
| Observability | CloudWatch metrics + logs, 2 dashboards as code, alarms |

Docs: [`docs/APPROACH.md`](./docs/APPROACH.md) · [`docs/CHALLENGES.md`](./docs/CHALLENGES.md)

---

## 1. Prerequisites

- Terraform >= 1.6
- AWS account + credentials (locally via `aws sso login` / env, in CI via GitHub OIDC)
- Node.js >= 20 and Docker (only for running the app locally)
- A GitHub repo with the following configured:
  - **Environment** `staging` (no reviewers)
  - **Environment** `production` (required reviewers = the manual approval gate)

## 2. Environment variables

The container never reads a `.env` file and never contains a credential. ECS injects these from
the `notes/<env>/db` secret in AWS Secrets Manager at task start:

| Variable | Meaning | Injected by |
| --- | --- | --- |
| `PGHOST` | RDS endpoint | ECS `secrets` block |
| `PGPORT` | RDS port | ECS `secrets` block |
| `PGUSER` | DB username | ECS `secrets` block |
| `PGPASSWORD` | DB password | ECS `secrets` block |
| `PGDATABASE` | DB name | ECS `secrets` block |
| `PG_SSL_MODE` | `require` against RDS | Task definition (non-secret) |
| `PORT` | HTTP port, default `3000` | Task definition (non-secret) |
| `LOG_LEVEL` | `info` / `debug` | Task definition (non-secret) |

`app/src/db.js` fails fast with a clear error if any `PG*` variable is missing — there is no
default password anywhere in the codebase. To run the app locally you must export these yourself
(or point at a local Postgres). This is intentional: a fallback password is a real credential
sooner or later.

## 3. Provision the infrastructure

```bash
cd terraform
terraform init
terraform fmt -check
terraform validate
terraform plan  -out=tfplan
terraform apply tfplan
```

State lives in S3 (`terraform/backend.tf`) and is locked with DynamoDB, so two people or two CI
jobs cannot apply at once. Re-point the bucket/table names in `backend.tf` to your own before the
first `init` — the bucket and lock table are created by `bootstrap/` (see below).

```bash
cd bootstrap           # one-time: creates the state bucket + lock table
terraform init
terraform apply
```

## 4. Build and push the image

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 537124981528.dkr.ecr.us-east-1.amazonaws.com

docker build -t notes-app:local ./app
docker tag   notes-app:local 537124981528.dkr.ecr.us-east-1.amazonaws.com/notes-staging/app:latest
docker push                       537124981528.dkr.ecr.us-east-1.amazonaws.com/notes-staging/app:latest
```

In normal use CI does this for you — see `.github/workflows/`.

## 5. Run the app locally

```bash
cd app
npm ci
export PGHOST=localhost PGPORT=5432 PGUSER=notes PGPASSWORD=<from your local DB> PGDATABASE=notes
npm run dev          # http://localhost:3000
npm test             # unit + integration tests (DB is stubbed)
```

## 6. CI/CD

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `pr-checks.yml` | pull request | unit + integration tests, `npm audit`, Trivy fs scan, `terraform fmt/validate/plan` |
| `deploy-staging.yml` | push to `main` | tests → Trivy image scan → build & push to ECR → `terraform apply` staging → smoke test |
| `deploy-production.yml` | `workflow_dispatch` | same build, `terraform apply` production — **blocked until a reviewer approves the `production` environment** |

That environment approval *is* the manual gate. Failures are published to the
`notes-staging-alerts` SNS topic — the same topic every CloudWatch alarm uses — which emails the
`alarm_email` subscriber. Email via SNS rather than a chat webhook keeps one notification channel
for alarms and pipeline failures, and needs no third-party app or rotating webhook secret.

### GitHub repository configuration

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `AWS_DEPLOY_ROLE_ARN` | output `github_deploy_role_arn` from `terraform apply` |
| Variable | `ALERTS_TOPIC_ARN` | output `alerts_topic_arn` from `terraform apply` |
| Environment | `staging` | no required reviewers |
| Environment | `production` | **required reviewers** — this is the manual approval step |

There are no GitHub secrets at all. The pipeline authenticates to AWS with OIDC and notifies
through SNS, so there is no `AWS_ACCESS_KEY_ID`, no `AWS_SECRET_ACCESS_KEY` and no chat webhook
URL to leak or rotate. `terraform/github.tf` creates the OIDC provider and a role whose trust
policy only accepts tokens from `repo:<owner>/<name>:*`.

## 7. Monitoring and logging

- **Metrics** — CloudWatch Container Insights (CPU, memory, disk, task count) for ECS; ALB target
  metrics (`RequestCount`, `TargetResponseTime`, `HTTPCode_Target_4XX/5XX_Count`) for request
  rate, latency and error rate; RDS Enhanced Monitoring + Performance Insights for the database.
  The app also exposes Prometheus-format `/metrics` so a scraper can be added with no code change.
- **Logs** — the `awslogs` driver ships application + system logs to CloudWatch Logs. ALB access
  logs land in S3. Retention: 14 days staging, 90 days production.
- **Dashboards** — created by Terraform from `monitoring/dashboards/*.json`:
  1. `infrastructure` — CPU / memory / disk / task count / DB CPU & connections
  2. `application` — request rate, 4xx/5xx rate, p90 target latency, healthy host count
- **Alarms** — 5xx spike, p90 latency, task CPU, task memory, unhealthy hosts → SNS → Slack/email.

## 8. Security

- All credentials live in **AWS Secrets Manager** and are decrypted only at task start. Nothing
  sensitive is in the repo, in a `.env`, or readable from the Terraform state output.
- `random_password` (32 chars) generates the DB password; the secret has `prevent_destroy`.
- Both ECS tasks and RDS sit in private subnets. No public IP on tasks, no SSH, no inbound rule
  to RDS from outside the VPC.
- Least-privilege security groups: `ALB :80/:443 → app :3000 → db :5432`.
- Container runs as UID 10001 (`node`), read-only root filesystem where the app allows it.
- GitHub Actions authenticates to AWS with **OIDC** — no long-lived access keys in secrets.
- Trivy blocks promotion on HIGH/CRITICAL image findings; `npm audit` covers dependencies.

## 9. Cost optimisation

- Fargate sized 0.25 vCPU / 512 MB, scaled on a CPU alarm (1–4 tasks).
- `db.t4g.micro`, single-AZ in staging, Multi-AZ is a one-line `multi_az` toggle in production.
- One NAT gateway for staging; per-AZ NATs only where HA is actually required.
- Log retention 14/90 days by environment; ALB access-log bucket has a lifecycle expiry.
- A monthly **budget alarm** in `monitoring/` warns at 80% of the configured budget.
- `terraform plan` runs on every PR so drift is caught before it costs money.

## 10. Backup strategy

- RDS automated backups with point-in-time recovery (7 days staging / 30 days production).
- `final_snapshot_identifier` set and `skip_final_snapshot = false`, so destroying the stack does
  not silently destroy the data.
- `deletion_protection` on in production.
- The Secrets Manager secret and the state bucket both have `prevent_destroy`.

## 11. Teardown

Three protections intentionally block `terraform destroy`. Turn them off first:

```bash
cd terraform

# 1. RDS deletion protection (default true)
terraform apply -var db_deletion_protection=false

# 2. The secret has `prevent_destroy`. Either edit secrets.tf to drop the block,
#    or detach it from state so Terraform leaves it alone:
terraform state rm aws_secretsmanager_secret.db aws_secretsmanager_secret_version.db

# 3. Now destroy everything else
terraform destroy
```

What survives teardown on purpose:
- The final RDS snapshot `notes-<env>-final-snapshot` — that is the backup strategy.
- The Secrets Manager secret if you used `state rm`, so the credential is still auditable.
- The state bucket and DynamoDB lock table — they live in `bootstrap/` and are never
  touched by `terraform destroy` here.

To wipe those too: `cd bootstrap && terraform destroy` (both have `prevent_destroy`, so
remove those blocks first).
