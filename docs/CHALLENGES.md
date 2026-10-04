# Challenges and resolutions

## 1. The PDF reader would not extract the assignment text
**Symptom.** `read_file` returned `Binary file: application/pdf` and refused to attach content;
`pdftotext` is not installed on this Windows host and `strings` was unavailable too.

**Resolution.** Installed `pdf-parse` into the session scratchpad and ran a 12-line Node script to
pull the text out. Nothing was added to the project itself.

**Takeaway.** Keep a fallback path for every tool. Had I assumed `pdftotext` existed, the build
would have started from a guess about the requirements.

## 2. Credentials leaking into state, logs and `.env` files
**Symptom.** `password = var.db_password` puts the credential in `terraform.tfstate`; a
`.env.example` full of plausible placeholder passwords is one copy-paste away from being a real
one; and `terraform plan` output is posted in CI where PR authors can see it.

**Resolution.** Removed the `.env` file from the design entirely. `random_password` generates the
password, it is written only into a **Secrets Manager** secret, the secret is marked
`prevent_destroy`, and ECS injects it at task start. `db.js` requires every `PG*` variable and
fails fast — there is no default password anywhere in the tree. CI runs `terraform plan` under a
read-only role and does not post plan output back to the PR body.

**Takeaway.** The safest secret is the one that is never materialised in a file. A "placeholder"
in a committed example file is still a credential-shaped hole.

## 3. Terraform state locking and blast radius
**Symptom.** Local state means two concurrent applies silently corrupt the stack, and
`terraform destroy` is one typo away from deleting the database.

**Resolution.** Remote state in S3 with a DynamoDB lock table, versioning and KMS on the bucket,
and `prevent_destroy` on the RDS instance, the secret and the state bucket. `skip_final_snapshot`
is `false` and `deletion_protection` is on in production.

**Takeaway.** State management is not a nice-to-have; it is the thing that makes IaC safe to share.

## 4. Choosing between Prometheus/Grafana and CloudWatch
**Symptom.** The brief asks for infra + app + DB metrics, centralised logs and two dashboards. A
Prometheus + Grafana + Loki stack covers all of it but is itself a service to deploy, secure,
patch and back up.

**Resolution.** Used CloudWatch (Container Insights, RDS Enhanced Monitoring, `awslogs` driver,
ALB access logs to S3) and defined both dashboards as JSON in Terraform so they are version
controlled. The app still exposes `/metrics` in Prometheus format, so Grafana or Prometheus can be
added later without touching application code.

**Takeaway.** The cheapest dashboard is the one you do not have to operate.

## 5. Getting application metrics without changing the app's job
**Symptom.** "Request rate, error rate, latency" are usually Prometheus concepts, but the stack is
CloudWatch-native.

**Resolution.** Capture the metric at the layer that already knows it: the ALB sees every request,
so `RequestCount`, `TargetResponseTime` and `HTTPCode_Target_5XX_Count` give all three with zero
app code. The `/metrics` endpoint is kept as an escape hatch, not as the primary source.

## 6. Manual approval for production in GitHub Actions
**Symptom.** There is no `approval` keyword in GitHub Actions, yet the brief explicitly asks for a
manual approval step before production.

**Resolution.** Modelled it as two workflows plus a GitHub **Environment** named `production` with
required reviewers. The production workflow only runs on `workflow_dispatch` and is bound to that
environment, so GitHub blocks the job until a reviewer approves it.

**Takeaway.** When a tool has no primitive for a requirement, look for the platform feature that
encodes the same policy — an environment gate is stronger than an in-script prompt because it is
audited.

## 7. Keeping the build inside the 9–12 hour budget
**Symptom.** Four broad parts plus "extra code that would help" — it would be easy to spend the
whole budget on the application.

**Resolution.** One resource (`notes`), one page, three endpoints. Every extra hour went into the
platform: OIDC auth, non-root container, image scanning, alarms, `prevent_destroy` on state and
data, budget alarm. Trade-offs are recorded here and in APPROACH rather than left implicit.

## 8. Circular dependency between RDS and the secret that describes it
**Symptom.** First draft of `rds.tf` had `depends_on = [aws_secretsmanager_secret_version.db]`,
while `secrets.tf` built `secret_string` from `aws_db_instance.this.address` and `.port`. Terraform
refuses to plan: the graph has a cycle.

**Resolution.** Removed the `depends_on` and re-pointed the ordering the other way. The natural
dependency is `random_password -> RDS -> secret_version`, and then
`secret_version -> ecs_service` so the first task can never start before the secret has a value.
`aws_ecs_service.app` now carries `depends_on = [aws_lb_listener.app_http, aws_secretsmanager_secret_version.db]`.

**Takeaway.** When a resource both *produces* and *consumes* a fact about another, split the
ordering: let the producer-dependency be implicit through attributes and only pin the one edge
that actually matters (here: "don't boot the task until the credential exists").

## 9. An invalid `aws_secretsmanager_secret_rotation` block
**Symptom.** I wrote a rotation resource with `rotation_lambda_arn = null` intending to fill it in
later. `terraform validate` rejects it — the attribute is required and must be a real ARN. An
`ignore_changes` on it does not help.

**Resolution.** Deleted the resource and left the wiring as a documented comment block in
`secrets.tf` showing exactly what to add once a rotation Lambda exists. Honest > half-configured.

**Takeaway.** Don't leave "TODO" resources in a plan — they fail at the worst moment (CI on the
deploy branch). A comment describing the upgrade path costs nothing and never breaks `validate`.

## 10. `PowerUserAccess` on the CI deploy role
**Symptom.** Terraform manages VPC, ECS, ECR, RDS, IAM, CloudWatch, S3, KMS and budgets. Writing a
least-privilege policy that enumerates every action is a large job and a common source of
mysterious CI failures.

**Resolution.** `PowerUserAccess` on the OIDC deploy role, called out in `github.tf` and here as a
known trade-off. It cannot manage IAM users/roles (so it cannot escalate itself), and the trust
policy restricts who can assume it to a single repository. Documented as the first thing to tighten
if this ever becomes a real production account.

**Takeaway.** A broad-but-bounded role plus a tight trust policy is safer than a hand-rolled policy
that someone will widen with `Action: "*"` the first time CI breaks.

## 11. Deploying with root account credentials
**Symptom.** `aws sts get-caller-identity` returned `arn:aws:iam::537124981528:root`. Not an IAM
user — the account root. Root access keys bypass every IAM policy (including the `PowerUserAccess`
boundary this project relies on for CI), cannot be permission-scoped per key, and are the highest
-value credential in the account.

**Resolution.** The decision was made to proceed with the root key for this assignment run rather
than pause the build. That is recorded here deliberately as a **known gap**, not as an
endorsement. Before this account holds anything of value:

1. Create an IAM admin user with a scoped policy, generate an access key for it, and use that.
2. Deactivate and delete the root access key:
   `aws iam delete-access-key --access-key-id <AKIA...> --user-name root` (run as root once).
3. Enable MFA on the root account and turn on the root sign-in CloudTrail alarm.
4. Re-apply `terraform/github.tf` and keep CI on the OIDC role — never give CI a root key.

**Takeaway.** "It works" is not the same as "it is safe." Flagging it in writing is the minimum
responsible move when the call is to accept the risk; the fix is a five-minute IAM change and there
is no reason to skip it past the demo.

## 12. A KMS key without a policy is not usable by CloudWatch Logs
**Symptom.** First `terraform apply` failed on the log group:

```
AccessDeniedException: The specified KMS key does not exist or is not allowed to be used
with Arn 'arn:aws:logs:us-east-1:...:log-group:/ecs/notes-staging/app'
```

The key existed and the caller had `kms:*`. The error is misleading — it is not about the caller.

**Resolution.** CloudWatch Logs encrypts *on the caller's behalf*, so IAM alone is not enough; the
key policy itself must name `logs.<region>.amazonaws.com` as a principal (RDS needs the same for
storage encryption, and both are scoped with conditions where possible). Added a five-statement
key policy: account root keeps `kms:*` so IAM delegation still works, then explicit grants for
CloudWatch Logs (conditioned on the log-group ARN), RDS, and Secrets Manager.

**Takeaway.** When a service encrypts something for you rather than you encrypting it, the trust
has to live in the key policy. And "does not exist or is not allowed" from KMS almost always means
*policy*, not existence — the error text sends you looking in the wrong place.

## 13. Pinning a PostgreSQL engine version that the region does not offer
**Symptom.** Second failure on the same apply:

```
InvalidParameterCombination: Cannot find version 16.3 for postgres
```

`16.3` was written from memory. Engine versions are regional and roll forward constantly; older
minors age out.

**Resolution.** Queried the region rather than guessing —
`aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion'`.
us-east-1 offers 16.9 through 16.15; pinned to `16.15` and documented the query in the variable
description so the next person does not have to rediscover it.

**Takeaway.** Never hard-code a provider-supplied version string from memory. Either query it at
plan time or leave the attribute unset and let the provider choose. Pinned versions are good
practice — but only when you confirm they exist.

## 14. A `terraform apply` that fails halfway leaves a stale saved plan
**Symptom.** The first apply ran in the background and died partway through, creating about
fifty resources. Re-running `terraform apply tfplan` then refused with
`Error: Saved plan is stale`, and the background log file was empty, so the real error was lost.

**Resolution.** Re-planned from the now-partial state (`terraform plan -out=tfplan`) and re-applied
in the foreground so the error text would be captured. Both real failures above were only visible
this way.

**Takeaway.** Two habits worth keeping: run `plan` immediately before `apply` against a state you
know has moved, and never run the first `apply` of a large stack in the background — if it dies,
you lose exactly the output you need. Also: `-out=tfplan` is only safe when nothing else touches
the state in between.

## 15. `db.t4g.micro` + `gp3` is not a combination every AZ can serve
**Symptom.** Third failure on the same stack:

```
InsufficientDBInstanceCapacity: You can't create a db.t4g.micro database instance because
there are no Availability Zones with sufficient capacity for VPC and storage type : gp3
for db.t4g.micro.
```

Not a quota error and not a configuration error — an actual capacity constraint, and only for
that specific pairing. `gp3` has a minimum IOPS/throughput floor that the smallest instance
classes cannot always satisfy in a given AZ.

**Resolution.** Switched `storage_type` to `gp2`, which is universally available at `db.t4g.micro`
and has no such floor. Left a comment at the resource to revisit if the instance class ever grows
past `db.t4g.medium`, where `gp3` becomes the better default again.

**Takeaway.** "Instance class, storage type, and AZ" is the real unit of capacity planning, not
any one of them. When AWS says "no capacity," try changing the *pairing* before concluding the
region is full — and prefer the boring storage class for the smallest instances.

## 16. BuildKit attestations + immutable ECR tags = a very confusing `400 Bad Request`
**Symptom.** `docker push` pushed every layer successfully and then failed at the very last step:

```
failed commit on ref "manifest-sha256:1eb80dd4...": unexpected status from PUT request to
https://....dkr.ecr.us-east-1.amazonaws.com/v2/notes-staging/app/manifests/latest: 400 Bad Request
```

Rebuilding with `--provenance=false --sbom=false` changed nothing. The error says nothing about
*which* constraint was violated.

**Root cause.** Two things collided:

1. Docker 27's BuildKit exports an **attestation manifest** alongside the real one and pushes both
   under a single manifest list. The very first push registered that 1,331-byte attestation stub
   as `:latest` before the commit of the real manifest failed.
2. `terraform/ecr.tf` sets `image_tag_mutability = "IMMUTABLE"`. Once `:latest` existed — even
   pointing at garbage — every subsequent push to that tag was rejected. With a bare `400`, not
   the `InvalidParameterException: tag already exists` you would hope for.

So each retry looked like a fresh failure when it was really the *first* failure blocking all the
others.

**Resolution.** `aws ecr describe-images` exposed the truth immediately: `:latest` existed, and
`imageManifestMediaType` was `application/vnd.oci.image.manifest.v1+json` with an
`artifactMediaType` and a `1331` byte size — an attestation artifact, not an application image.
Deleted it with `aws ecr batch-delete-image` to free the tag, rebuilt with `--provenance=false`,
pushed clean.

**Takeaway.** When a push "fails" but `describe-images` shows something already there, you are
fighting your own earlier attempt, not the registry. And `400 Bad Request` from a registry PUT is
almost always a policy or format rejection — go read the resource state before retrying blindly.
Two things worth carrying forward: keep `--provenance=false` (or pin `BUILDKIT_EXPORT`) when
targeting ECR, and prefer immutable *per-build* tags (`sha-<commit>`) over a mutable-looking
`:latest` in an immutable repo — CI in `.github/workflows/` already does this.
