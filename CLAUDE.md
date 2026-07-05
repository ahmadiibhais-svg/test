# CLAUDE.md — Avertra Sr. DevOps Assessment (Sock Shop on AWS)

## What this project is
Take-home technical assessment for a Senior DevOps Engineer role at Avertra. **Deadline: submit by July 8, 2026** (target: finished Wednesday July 8 midday). Deliverables: (1) working IaC + automated deployment of the Sock Shop microservices demo app, (2) comprehensive documentation, (3) a short presentation (slides + 3-min screen recording). Ahmad will **defend this live** in front of the DevOps team lead — every decision must be explainable by him, not just by the code.

Detailed phase-by-phase playbook lives in the skill: `.claude/skills/avertra-sockshop-assessment/SKILL.md`. Consult it at the start of every session and every phase.

## Who you're working with
Ahmad is a senior DevOps engineer: strong in Kubernetes/Helm, CI/CD (TeamCity, Octopus, GitLab, GitHub Actions), Windows/Linux ops, monitoring operations (SCOM/PRTG/Dynatrace), DevSecOps (CodeQL/SAST). He is a **beginner in Terraform and AWS** (has used EC2/ELB/Elastic Beanstalk as a user only, zero AWS monitoring experience, never connected GitLab to AWS).

Consequences for how you work:
- Every new AWS or Terraform concept gets a 1–2 sentence "why," not just "what." Teach as you go.
- Map new concepts to what he knows when possible (ECS service ≈ K8s Deployment+Service; task definition ≈ pod spec; Service Connect ≈ K8s Service DNS; target tracking scaling ≈ HPA).
- He must be able to defend every line. No magic. If he asks "why is this here," the answer should already have been given.

## Non-negotiable working agreements
1. **Small steps.** One logical unit per change (one module, one service). Never bulk-generate the whole infrastructure in one shot.
2. **Plan before apply.** Before every `terraform apply`: summarize the plan output in plain language, explicitly flag anything that costs money or is destructive, and wait for Ahmad's go-ahead. He runs or approves every apply.
3. **DECISIONS.md is sacred.** Log every meaningful decision as it's made: what was decided, alternatives considered, why. This file becomes the documentation deliverable almost for free.
4. **Cost discipline.** Personal AWS account. Smallest viable sizes. At the end of every work session: scale services to 0 or `terraform destroy` the app stack (state and ECR live in a separate bootstrap stack precisely so destroy is safe). Destroying and recreating is not waste — it is proof of IaC repeatability and goes in the demo.
5. **No secrets in code or repo.** SSM Parameter Store (SecureString) + ECS secrets injection. `.gitignore` covers `.terraform/`, `*.tfstate*`, `*.tfvars` (keep a `terraform.tfvars.example`). Never echo secret values.
6. **Verify from source, not memory.** Day 1: clone https://github.com/microservices-demo/microservices-demo and extract per-service ports/env/health endpoints from `deploy/kubernetes/complete-demo.yaml` into `SERVICES.md`. That file is the source of truth over any assumption (including assumptions in the skill file marked VERIFY).
7. **End-of-session ritual:** update DECISIONS.md, confirm AWS spend state (what's still running), commit, then ask Ahmad 2–3 defense-style questions about what was just built (e.g., "why a NAT gateway in only one AZ?"). This doubles as his interview prep.

## Locked architecture decisions (do not silently change; propose changes explicitly)
- **Region:** us-east-1. **IaC:** Terraform, remote state in S3 with locking. **CI/CD:** GitLab CI. **Cloud:** AWS.
- **Compute: ECS on Fargate — chosen over EKS deliberately.** Rationale (documented, will be defended): time-boxed assessment; no control-plane fee or cluster operations; delivers the same required outcomes (HA, scaling, fault tolerance, automated deploys). Docs must include a "Path to Kubernetes/EKS" section to show the trade-off was informed, not ignorant.
- **App:** Sock Shop, using the **pre-built public images** (weaveworksdemos/*). We do not build application code. The pipeline mirrors upstream images → scans → pushes to our ECR → deploys from ECR (supply-chain control story).
- **Two Terraform roots:** `bootstrap/` (S3 state bucket, ECR repos, OIDC provider, budget — applied once, never destroyed) and `main/` (everything else — destroyable nightly).
- **Network:** 1 VPC, 2 AZs. Public subnets: ALB + 1 NAT gateway (single NAT = documented cost trade-off; prod = one per AZ). Private subnets: all Fargate tasks + RDS. S3 gateway VPC endpoint (free, cuts NAT data for ECR layer pulls).
- **Edge:** ALB replaces the sock-shop `edge-router` entirely. ALB → front-end service only. Everything else is internal.
- **Service discovery:** ECS Service Connect, one namespace; discovery names must exactly match the hostnames baked into the images: `catalogue`, `carts`, `orders`, `shipping`, `payment`, `user`, `queue-master`, `rabbitmq`, `carts-db`, `orders-db`, `user-db`.
- **Data tier:** catalogue-db → **RDS MySQL** (db.t4g.micro, `multi_az` as a variable — flip on for final demo; seed from the catalogue repo's dump.sql). carts-db / orders-db / user-db → mongo containers on Fargate (**ephemeral by design** — documented trade-off; prod = DocumentDB/Atlas). rabbitmq → container on Fargate (prod = Amazon MQ).
- **Security groups (least-privilege chain):** alb-sg (80 from world) → frontend-sg (front-end port from alb-sg only) → backend-sg (80 from frontend-sg + self, for service-to-service) → data-sg (27017/5672 from backend-sg) and rds-sg (3306 from backend-sg). No SSH anywhere, no public IPs on tasks.
- **Deployment safety:** ECS rolling update + deployment circuit breaker with auto-rollback enabled. Documented as the rollback story; CodeDeploy blue/green named as the production upgrade path.
- **Advanced features (in priority order):** (1) auto-scaling policies on application metrics, (2) security scanning in the pipeline (Trivy images + tfsec/Checkov on Terraform + ECR scan-on-push), (3) drift detection via scheduled `terraform plan -detailed-exitcode` job — do this one only if Tuesday is going well.

## Scope safety valve
If full 12-service deployment is not working by end of Sunday: cut to the core journey — front-end, catalogue (+RDS), user (+user-db), carts (+carts-db). That demonstrates every required capability (browse, register, cart). Document the checkout chain (orders, payment, shipping, rabbitmq, queue-master) as "same module pattern, omitted for time." A complete, polished core beats a broken whole.

## Cost guardrails
- AWS Budget at $25/month with alerts at 50/80/100% (+ forecast alert). Confirm it exists before creating any billable resource.
- Biggest silent costs to watch: NAT gateway ($0.045/hr while it exists, even idle), Fargate tasks left running overnight, Container Insights metrics.
- Everything sized minimal: Fargate 0.25 vCPU/512MB default (0.5/1GB for the Java services), RDS db.t4g.micro, log retention 7 days.

## Repo layout (target)
```
.
├── CLAUDE.md
├── .claude/skills/avertra-sockshop-assessment/SKILL.md
├── DECISIONS.md          # running decision log → becomes docs
├── SERVICES.md           # extracted service specs (ports/env/health) — source of truth
├── bootstrap/            # TF root 1: state bucket, ECR repos, OIDC, budget (apply once)
├── terraform/            # TF root 2: envs/dev + modules/{network,alb,ecs-cluster,ecs-service,rds,monitoring}
├── pipeline/.gitlab-ci.yml
├── docs/                 # final documentation deliverable
└── slides/               # presentation
```

## Current status (updated at each session close — last: Sunday 2026-07-05, night)
Phases 0–4 COMPLETE — a full day ahead of plan. Sunday delivered: timed rebuild **5m45s**
(docs number) + D12 clean-room pass; Phase 3 CI/CD fully live (OIDC passports, zero stored
creds — after the recycled-path/project-ID saga; two-flow pipeline; 13 images mirrored to
ECR via Trivy; all services flipped to ECR :stable THROUGH the pipeline's manual apply,
zero 5xx across the roll); Phase 4 monitoring live (7-widget dashboard, 5 alarms,
ALARM+OK emails evidenced); D8 immutable-tags walkthrough DELIVERED; nightly destroy is
now a double-locked pipeline button (D14) and ran green — account cold, dev state empty,
bootstrap alive. Spend ≈$3–4 of $140. Decisions D1–D14; lessons L1–L19 + bank Q1–28.
MONDAY: Phase 5 — auto-scaling (target tracking on front-end; user-sim load = the money
shot, will also trip alarms organically = metric-driven alarm proof), security-scan
hardening (.trivyignore allowlist from the harvested CVEs; tfsec allowlist incl. the 13
MUTABLE findings → cite D8), drift detection if time. Then Phase 6 docs/slides/recording
(Tue) — submit Wed. Open items: browser-journey screenshots STATUS UNCONFIRMED (ask!),
L18/L19 reading, encryption read-back, defense Qs, skill-file-in-repo decision. Teaching
style contractual: word-by-word, narrative not tables, his vocabulary (the diary, the
toll road, the sealed box, chain links, the spy, the passport).

## Session start ritual
1. Read DECISIONS.md tail + current phase in the skill.
2. `terraform state list` / AWS console sanity check: what exists right now, what is it costing.
3. State today's phase goal and acceptance criterion out loud before touching anything.
