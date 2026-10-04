# Architecture decisions

## Application
A deliberately small **Notes** API (Express + PostgreSQL) with one static HTML page. The brief says
application logic is not important, so effort went into the platform rather than the product.
Express + `pg` was chosen over a heavier framework so the image stays small and the happy path is
easy to reason about. The app is stateless, so it scales horizontally without sticky sessions.

## Secrets — AWS Secrets Manager
This was the decision that shaped the most code.

- `random_password` (32 chars) generates the RDS master password. It is never a Terraform variable
  default, never in the repo, and never written to a `.env`.
- A single JSON secret `notes/<env>/db` holds `{username, password, host, port, dbname}`.
- The ECS task definition uses `secrets { valueFrom = "<arn>:json-key::" }` so ECS decrypts it at
  task start and injects `PGUSER`, `PGPASSWORD`, `PGHOST`, `PGPORT`, `PGDATABASE` into the
  container environment.
- The app reads only env vars and **fails fast** when one is missing. `app/src/db.js` has no
  default password — a fallback is a real credential the moment someone commits a "temporary" one.
- The secret carries `prevent_destroy` and is encrypted with a KMS CMK.

Trade-off: fetching the secret in-app (via `@aws-sdk/client-secrets-manager`) would make the
dependency on Secrets Manager explicit in code, but it couples the app to AWS and means every
local run needs an IAM identity. ECS injection keeps the app cloud-agnostic and local dev trivial.

## Compute — ECS Fargate over EC2 / EKS
- **EKS** would add a control plane to run, patch and pay for. Out of scope for a 9–12 hr happy path.
- **EC2 + ASG** would need AMI baking or user-data, patching, and capacity management.
- **Fargate** gives container hosting, task-level IAM and Container Insights with no nodes to own.
  Tasks run in **private subnets**; only the ALB is public.

## Network
Two-tier VPC across two Availability Zones.

- Public subnets → ALB and NAT gateways.
- Private subnets → ECS tasks and RDS.
- One NAT gateway per AZ for HA (staging runs one to save money — see cost notes).

Security groups follow least privilege in a strict chain: `ALB → app → database`. No bastion, no
SSH, no inbound rule to RDS from the internet.

## Database — RDS PostgreSQL
Managed RDS rather than self-hosted Postgres:

- Automated backups, point-in-time restore and a final snapshot come with it.
- Multi-AZ is a one-line toggle for production.
- Enhanced Monitoring + Performance Insights give DB metrics without installing exporters.

## State management
Remote state in **S3** with:

- Versioning enabled and `force_destroy = false`.
- **DynamoDB** lock table so two applies cannot race.
- Server-side encryption with a KMS CMK.
- `prevent_destroy` on the bucket.

The state bucket and lock table are created by a tiny `bootstrap/` stack so they survive
`terraform destroy` of the main stack. State locking is what separates a demo from something safe
to run in a team.

## CI/CD
Three workflows rather than one monolith, so triggers map cleanly to risk:

1. **PR checks** — tests, `npm audit`, Trivy fs scan, `terraform fmt/validate/plan`. Read-only.
2. **Deploy staging** — on merge to `main`; image scan → push to ECR → `terraform apply` staging.
3. **Deploy production** — `workflow_dispatch`, bound to a GitHub **Environment** with required
   reviewers. That is exactly the "manual approval step for production" the brief asks for.

AWS auth uses **GitHub OIDC** (`AssumeRoleWithWebIdentity`), so there are no long-lived access
keys in repository secrets to rotate or leak.

## Environments: two defined, one deployed
The brief asks for a staging deploy *and* a manual approval step before production, so both
environments exist as deployable targets in the pipeline. Only **staging is provisioned** in AWS.
Two reasons:

- **Cost.** A second environment is a full parallel stack — its own VPC, RDS instance, ALB and
  NAT gateway. That roughly doubles the running spend from about $2.40/day to $5/day for a
  three-day exercise that carries no real traffic.
- **The requirement is the gate, not the fleet.** What the brief actually specifies is the
  *approval step* between staging and production. That is demonstrated in `deploy-production.yml`
  — a `workflow_dispatch` bound to a `production` GitHub Environment with required reviewers —
  exactly the same whether or not the second stack is provisioned.

Promotion to a real production environment is one command, and the code is already parameterised
for it:

```bash
cd terraform
TF_VAR_environment=production terraform plan  -out=tfplan
TF_VAR_environment=production terraform apply tfplan
```

Every resource is named `notes-<environment>-*`, so two stacks cannot collide, and variables
already carry environment-specific behaviour: `deletion_protection` and Multi-AZ on in
production, `LOG_LEVEL=info` versus `debug`, 90-day versus 14-day log retention, and
`enable_deletion_protection` on the ALB only in production.

Deploying one environment and saying so out loud felt like the better trade than quietly
provisioning a second stack nobody would look at.

## Observability
CloudWatch over a self-hosted Prometheus/Grafana/Loki stack:

- Zero extra infrastructure to run, patch, secure and back up.
- Container Insights covers infra metrics for Fargate.
- RDS Enhanced Monitoring + Performance Insights covers the database.
- Centralised logging via the `awslogs` driver (application + system) and ALB access logs to S3.

Two dashboards ship as JSON under `monitoring/dashboards/` and are created by Terraform:

1. **infrastructure** — CPU, memory, disk, task count, DB CPU and connections.
2. **application** — request rate, 4xx/5xx rate, p90 target latency, healthy host count.

Application metrics come from two layers. The ALB already sees every request, so `RequestCount`,
`TargetResponseTime` and `HTTPCode_Target_5XX_Count` give rate / latency / error rate with zero
app code. The app still exposes Prometheus-format `/metrics` via `prom-client` so a scraper can be
added later without a code change.

Alarms cover the four failures that actually wake someone: 5xx spike, high p90 latency, task
CPU/memory saturation, low healthy host count.

## Cost optimisation
- Fargate right-sized to 0.25 vCPU / 512 MB, scaled 1–4 tasks on a CPU alarm.
- `db.t4g.micro`; single-AZ in staging, Multi-AZ toggle in production.
- Single NAT gateway in staging.
- Log retention 14 days staging / 90 days production.
- ALB access logs to S3 with lifecycle expiry; monthly budget alarm at 80%.
