# 02 — Setup & Run: from an empty AWS account to a working shop

This a from-scratch walkthrough. Following it end to end takes roughly **45–60 minutes of hands-on time** (most of it waiting on two pipeline stages) and finishes with the storefront serving traffic behind an ALB, seeded, monitored, and auto-scaling. Architecture and rationale: [01-architecture.md](01-architecture.md).

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | New accounts on the credits-based free plan work; a payment method must be attached. Everything below assumes **us-east-1**. |
| Local AWS credentials | Bootstrap runs from your machine: an IAM user with administrative access for the initial setup, configured via `aws configure`. (Only bootstrap uses these — the pipeline authenticates via OIDC and stores nothing.) |
| Tools | AWS CLI v2 · Terraform ≥ 1.10 (pipeline uses 1.15) · git. **Docker is not required locally** — all image work happens in the pipeline. |
| GitLab.com account | Free tier is sufficient. |

## 2. One-time personalization — every value you must change

These are the only lines in the repository that carry my identifiers. Change them **before** anything else; each is called out again at the step where it matters.

| # | Value | Where | Notes |
|---|---|---|---|
| 1 | GitLab **numeric project ID** | `bootstrap/oidc.tf` — the trust policy's `sub` condition (`project_id:<ID>:*`) | Found on your project page (⋮ menu → *Copy project ID*). Must be set **before** bootstrap apply. The numeric ID is used deliberately — project *paths* are recyclable; IDs are not. |
| 2 | **State bucket name** | `bootstrap/` (bucket resource) **and** `terraform/envs/dev/backend.tf` | S3 bucket names are globally unique, and Terraform backend blocks cannot read variables — so the name is a literal in **two places** and must match. |
| 3 | **AWS account ID / ECR hostname / role ARN** | `.gitlab-ci.yml` `variables:` block | Account ID and ECR host now; the role ARN can be obtained from the IAM console — paste it after step 4. These are identifiers, not secrets: the security lives in the OIDC trust conditions. |
| 4 | **Alert email** | `terraform/envs/dev/monitoring.tf` | SNS subscription target — you will confirm it by email after apply. |
| 5 | **Budget email** | `bootstrap/` (budget resource) | Cost alerts at 50/80/100% of $25. |

## 3. GitLab project setup

1. **Validate your account for shared runners.** New GitLab accounts require a one-time card validation before shared runners execute anything (Settings → Billing; nothing is charged). Skipping this will result in the pipeline stuck in *pending* state.
2. Create a project (private is fine) and **copy its numeric project ID** into `bootstrap/oidc.tf` (item 1 above).
3. Confirm defaults: `main` is a **protected branch** (Settings → Repository) — the pipeline's mutating jobs only exist on main, and branch protection is part of what the OIDC identity attests. confirm that Instance runners are **enabled** (Settings → CI/CD → Runners).
4. Do **not** push yet — pushing creates a pipeline, and the pipeline needs the role ARN from bootstrap first.

## 4. Bootstrap — the one-time, local apply

Bootstrap creates the things everything else stands on: the S3 state bucket, thirteen ECR repositories (scan-on-push enabled), the GitLab OIDC identity provider and the CI role, and the $25 budget with alerts. It runs **locally, once, with local state** — deliberately: the state bucket cannot store the record of its own creation, and keeping bootstrap outside the pipeline means the destroy job can never touch it.

```bash
cd bootstrap
terraform init
terraform plan     # review: bucket, 13 ECR repos, OIDC provider + role, budget
terraform apply
```

**Copy the CI role ARN from IAM console to `.gitlab-ci.yml`'s `AWS_ROLE_ARN` variable** (item 3). Keep the `bootstrap/` directory and its local state file — it is the only record of these resources.

Now push the repository:

```bash
git remote add origin git@gitlab.com:<you>/<project>.git
git push -u origin main
```

The push triggers the first pipeline. The **validate stage** (fmt, validate, tfsec — blocking, with all findings triaged inline) and **tf-plan** run automatically. tf-plan is also the first live test of the OIDC handshake — if it fails at STS, check in order: the role ARN variable, the project ID in the trust policy, and that you pushed to `main`.

## 5. First bring-up — the order is a law, not a suggestion

> ⚠️ **Mirror before apply.** The task definitions reference images in *your* ECR (`…:stable`), and those repositories are empty until the mirror jobs fill them. Apply first and all thirteen services will crash-loop in PENDING with `CannotPullContainerError`. (Manual jobs don't block later stages in GitLab, so the mirror buttons are pressable immediately — they need only ECR and the OIDC role, both of which bootstrap created.)

1. **Press the 13 `mirror` jobs** (mirror stage — they run in parallel, ~5–10 minutes total). Each pulls its pinned upstream image, scans it with Trivy, and pushes `:sha` and `:stable` tags to ECR. Trivy **will** report findings on the frozen 2016–2018 images — that is expected and documented policy: the report is a risk manifest (see `.trivyignore` and [04-tradeoffs.md](04-tradeoffs.md)); the blocking gate applies to anything new.
2. **Review the plan.** Open tf-plan's `plan.txt` artifact — roughly sixty resources: VPC, ALB, cluster, RDS, thirteen services, monitoring, auto-scaling.
3. **Press `tf-apply`** (~12–18 minutes; RDS takes sometime). What was reviewed is byte-for-byte what executes — apply consumes the saved plan artifact, never a fresh plan.
   - *First-ever ECS use in a brand-new AWS account only:* cluster creation can fail once with "Service Linked Role is not ready" — AWS is creating ECS's service-linked role in the background and the request raced it. **Retry the job a minute later**; it is a one-time-per-account event.
4. **Confirm the SNS subscription.** Check the alert-email inbox and click AWS's confirmation link — until you do, alarms deliver nothing.
5. **Press `seed`.** The job looks up the current private subnets and security group by their stable names, launches the seeding task (job), waits for it to stop, and greps its log for `SEED COMPLETE` — the job fails if seeding did.
6. **Verify.** Get the storefront URL from (EC2 Load Balancer, then click on sockshop-alb) and open it.
   Walk the full journey: catalogue shows socks → register and log in → add to cart → checkout creates an order. Then open the CloudWatch dashboard (`sockshop-overview`) and watch your own clicks appear in the request and latency widgets.

## 6. Day-2 operations — the pipeline buttons

Everything operational is a manual job on `main`; nothing mutating ever runs automatically.

| Button | What it does | Notes |
|---|---|---|
| `deploy` (per service) | `--force-new-deployment` + waits for steady state | Run after re-mirroring: refreshes both the `:stable` image **and** the service's Service Connect snapshot. Red job = the deployment circuit breaker rolled back. |
| `load-demo` | Fires the user-sim load generator at the ALB | `CLIENTS` / `REQUESTS` are editable when you press play (defaults 10 / 10 000 ≈ 6 minutes — **`-r` is total requests, not a rate**). Watch the dashboard: requests-per-target climbs, front-end steps 2 → 5, p99 stays flat. note that it could take sometime for the auto-scaling to kick in due to AWS-managed alarms created by target tracking |
| `load-stop` | Stops any running generator tasks | Scale-in follows on its own after the quiet window — the autoscaler removes capacity conservatively by design. |
| `drift-check` | `terraform plan -detailed-exitcode` — exit 2 = reality was edited outside Terraform | It can run on **main** push and also runs **on schedule**, this can be tested by running destroy and then running the drift-check (it should give you a fail here), or can be run after you run tf-plan and tf-apply (it should give you green here) |
| `tf-destroy` | Tears down the dev environment | Double-locked: manual **and** requires typing the variable `CONFIRM_DESTROY=sockshop-dev` when pressing play. Bootstrap (state, ECR, OIDC, budget) is structurally out of its reach. |

## 7. The rebuild ritual (and why destroy is safe)

The environment is designed to be destroyed when idle — the NAT gateway and Fargate tasks bill by the hour whether busy or not. Because bootstrap survives every destroy, **rebuilds never repeat the mirror step**: images and state persist in ECR and S3.

Rebuild = three button presses: `tf-apply` → `seed` → verify. Measured rebuild time from nothing to a serving, seeded storefront: **10 minutes** — that number is this project's repeatability proof.

## 8. Full teardown to zero

Press `tf-destroy` (with the typed confirmation, if the confirmation box didnt appear, add the following as a variable. click on **Settings** -> **CI/CD** -> **Variables** -> **Key**=CONFIRM_DESTROY, **Value**=sockshop-dev, then re-run **tf-destroy**) — removes the dev environment.

---

*Next: [03-requirements-mapping.md](03-requirements-mapping.md) — every assessment requirement, the component that satisfies it, and the evidence.*
