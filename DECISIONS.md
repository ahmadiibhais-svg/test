# Decision Log — Avertra Sock Shop Assessment

Running log of every meaningful decision, captured as it is made. Format per entry:
**what was decided · alternatives considered · why.** This file feeds the documentation
deliverable directly.

The *locked* architecture decisions (ECS Fargate over EKS, single NAT, RDS for
catalogue-db, ephemeral Mongo, Service Connect, etc.) live in `CLAUDE.md` and will be
expanded with full rationale in `docs/` during Phase 6. This log records the decisions
made **during the build**.

---

## Phase 0 — Foundations (2026-07-04)

### D1 — Skip the AWS credit-earning activities
- **Decided:** Do **not** walk through the five AWS "new credits plan" earning activities
  (Budgets, RDS, EC2, Lambda, Bedrock) for the sake of the ~$200 in credits.
- **Alternatives:** Complete all five activities to bank credits.
- **Why:** Account already holds **$140 in credits** — more than enough headroom for a
  time-boxed assessment sized to a $25/mo budget. The activities would cost build time for
  a benefit we don't need. (Budgets and RDS still get created — because the architecture
  needs them, not to farm credits.)

### D2 — CLI access via a dedicated IAM user, not root access keys
- **Decided:** Create IAM user `ahmaddemo` with `AdministratorAccess` for the assessment
  week; configure the AWS CLI with its access key. Root is used only to bootstrap this user.
- **Alternatives:** Generate root account access keys; use AWS IAM Identity Center (SSO).
- **Why:** Root keys are unrevocable and grant unrestricted account+billing power — AWS
  explicitly recommends against creating them. A named IAM user is auditable and revocable.
  `AdministratorAccess` is a deliberate convenience for a one-week solo assessment; the
  **production** recommendation (documented in `docs/`) is SSO with least-privilege roles.
- **Note (key hygiene):** the user's first access key was exposed outside the terminal during
  setup and was immediately deactivated and replaced — access keys are treated as radioactive;
  exposure = rotation, no exceptions. (Same discipline the pipeline follows: no secrets in
  code, chat, or logs — SSM SecureString only.)

### D3 — Tooling baseline verified
- **Decided:** Proceed on Terraform v1.15.7, AWS CLI v2.35.15, git 2.55, Docker 29.6.1.
- **Why:** Terraform ≥1.10 is required so remote state can use the **native S3 state
  lockfile** (the `use_lockfile` argument) instead of a separate DynamoDB lock table —
  one less resource to provision and pay for. All versions clear that bar.

### D4 — Add session-db (Redis) for shared front-end sessions
- **Decided:** Deploy `session-db` (redis:alpine, port 6379) as a 13th Fargate service and set
  `SESSION_REDIS=true` on front-end, matching the upstream K8s manifest. Adds SC name
  `session-db` to the discovery list and a 13th ECR repo.
- **Alternatives:** (a) In-memory sessions + ALB sticky sessions (cookie-based target
  pinning) — one fewer container, but a session lives and dies with a single front-end
  task, so the fault-tolerance demo (kill a task, site keeps working) would log the user
  out. (b) ElastiCache Redis — managed, but overkill cost/complexity for a demo session store.
- **Why:** front-end runs at desired_count 2 behind the ALB and is the auto-scaling target
  (min 2 → max 5). An e-commerce session (login + cart) must survive round-robin routing,
  scale-in, and task failure — that requires an external shared session store, not task
  memory. This is the same reason stateless pods in K8s externalize session state. Found by
  the day-1 "verify from source" pass: `complete-demo.yaml` deploys session-db + sets
  `SESSION_REDIS=true`, while the compose file omits both (single-instance assumption).
  Ephemeral like the other Mongo containers (documented trade-off; prod = ElastiCache).

### D5 — Pin MongoDB to `mongo:3.4` for carts-db and orders-db
- **Decided:** Task definitions for `carts-db` and `orders-db` use the image **`mongo:3.4`**,
  exactly as pinned in `deploy/docker-compose/docker-compose.yml:60,86`.
- **Alternatives:** (a) Untagged `mongo` as in `deploy/kubernetes/complete-demo.yaml:94,408` —
  untagged means `:latest`, which in 2026 resolves to MongoDB 8.x. (b) An intermediate
  version (e.g. 4.x) — newer, but never tested by upstream against these services.
- **Why (the versioning problem):** the database *clients* are `carts:0.4.8` and
  `orders:0.4.7` — Java/Spring apps frozen in ~2017–2018, embedding Spring Data MongoDB
  drivers of that era. MongoDB **removed the legacy wire protocol (OP_QUERY) server-side in
  5.1+**, so a 2017 driver pointed at a modern Mongo 7/8 server can fail its handshake
  outright — the visible symptom would be carts/orders flapping with connection errors and
  no obvious cause. The K8s manifest's untagged image is a rotted `:latest`: it worked when
  the manifest was written (latest ≈ 3.x then) and silently broke as Docker Hub moved on.
  Pinning to the version the application was actually built against is the same image-pinning
  discipline applied in any Helm chart review. **Two lessons captured for docs:** (1) never
  ship unpinned image tags; (2) when two deployment descriptors disagree, trust the pinned one.
- **Accepted side-effect (feeds Phase 5):** `mongo:3.4` is EOL with known CVEs — Trivy will
  flag it. That goes in the accepted-risk register with justification: isolated demo
  container, private subnet, no public path, no inbound except backend-sg on 27017,
  ephemeral data. "Scanning without a triage policy is noise" — this is the triage policy.

### D6 — user service: `user:0.4.4` + `MONGO_HOST=user-db:27017`
- **Decided:** Task definition for `user` uses image **`weaveworksdemos/user:0.4.4`** with
  env **`MONGO_HOST=user-db:27017`** (`docker-compose.yml:146,155`).
- **Alternatives:** (a) `user:0.4.7` + env literally named `mongo` as in
  `complete-demo.yaml:778,789-790`. (b) No env at all — the image's built-in default DB host
  is `user-db`, and our Service Connect name is exactly `user-db`, so it would still resolve.
- **Why:** the two upstream descriptors contradict each other on both the app version and the
  env-var *name* the app reads for its DB address (the value is identical). We keep the whole
  deployment on **one internally-consistent, pinned set** — the compose set, the same one
  that correctly pins `mongo:3.4` (see D5) — rather than mixing halves of two contradictory
  sources. `MONGO_HOST` is also the explicit, self-documenting name. The descriptor
  recommending `0.4.7` is the same one that shipped unpinned `mongo:latest`, which lowers
  its credibility as a source. Defense line: "when sources conflict, pick the coherent set
  and write down why — don't cherry-pick."

### D7 — Bootstrap root design: local state, TF-managed budget, OIDC deferred
- **Decided:** (a) `bootstrap/` keeps **local** Terraform state. (b) The **$25/month budget**
  with 50/80/100% actual + 100% forecast email alerts is created **by Terraform** in
  bootstrap; the hand-made console budget ("My Budget", $40/**daily**, created during
  account setup) is left untouched and treated as superseded — a $40/day threshold would
  only fire after burning 1.6× our monthly budget in a single day, useless as a guardrail.
  (c) The GitLab **OIDC provider + deploy role are deferred to Phase 3** (CI/CD).
- **Alternatives:** (a) migrate bootstrap state into the bucket after creation — an extra
  moving part for a tiny, static stack; (b) manage the budget by console — but guardrails
  belong in code; (c) create OIDC now.
- **Why:** (a) chicken-and-egg: the bucket that stores state can't store the state of its
  own creation; bootstrap is small, applied once, never in the nightly destroy path.
  (c) The OIDC role's trust policy must be conditioned on the exact GitLab project path,
  which doesn't exist yet. "Applied once, never destroyed" ≠ "never amended" — Phase 3
  adds OIDC to bootstrap with a small additive apply.
- **Account facts recorded 2026-07-04:** new free tier, plan = **FREE**, **$140 credits,
  expire 2026-10-20** (well past the deadline). FREE plan cannot bill the card — spend is
  hard-capped by credits (a safety property), but some non-eligible services may be blocked;
  treat unexplained AccessDenied/subscription errors as a plan-restriction signal. Upgrade
  path if ever needed: switch to paid plan (credits still spend first).

### D8 — Image tagging: mutable `:stable` + unique SHA tag for the assessment; IMMUTABLE is the production pattern
- **Decided:** ECR repositories use `image_tag_mutability = "MUTABLE"` (bootstrap/ecr.tf).
  The Phase-3 pipeline will push every image **twice**: once tagged with the pipeline's
  commit SHA (unique, never reused — the audit trail) and once as **`:stable`** (a movable
  pointer meaning "current good one"). Task definitions reference `:stable`; deploying =
  re-pointing `:stable` and forcing a new ECS deployment, so the task definition itself
  never has to change.
- **Alternatives:** IMMUTABLE repositories + a unique tag (or, strictest, the digest
  `image@sha256:…`) per deploy, with the reference driven through Terraform so every deploy
  is a reviewable diff.
- **Why mutable here:** time-boxed assessment — the mutable scheme keeps the pipeline and
  task definitions simple, while the parallel SHA tags preserve "what exactly was running
  when" evidence. The weaknesses of a movable pointer are understood, accepted, and
  documented rather than ignored:
  1. **Audit:** the name in the task definition (`:stable`) doesn't identify the bytes —
     the pointer has moved since.
  2. **Rollback:** re-pointing is rollback-by-trust; a unique tag is rollback-by-reference.
  3. **Security:** compromised registry credentials could silently re-point `:stable` so the
     next restart deploys an attacker's image under an innocent name.
- **Production path (for docs + defense):** flip repos to IMMUTABLE, pin task definitions to
  the unique tag or digest, drive each change through Terraform/merge request — explicit,
  reviewable deploys and exact rollbacks.
- **Follow-up promised to Ahmad:** after Phase 3 is green, a knowledge-only walkthrough of
  exactly how the Terraform + pipeline wiring would change for the immutable pattern.

---

## Phase 1 — Walking skeleton (2026-07-04)

### D9 — Phase-1 implementation decisions (bundle)
- **Subnets written explicitly, no loops:** at n=2 AZs, four named blocks beat a clever
  loop for readability/defense; loops earn their place at n=13 (ecs-service instantiations).
- **SG placement:** `alb-sg` lives INSIDE the alb module (belongs to the ALB); tier SGs
  (frontend-sg, later backend/data/rds) live at the ROOT — they are the wiring BETWEEN
  modules. Chain enforced on ingress with SG-as-source (identity, not IPs); egress open.
- **One shared private route table** — honest reflection of the single-NAT decision;
  multi-NAT production splits per AZ. `map_public_ip_on_launch` false everywhere.
- **ALB tuning:** deregistration_delay 30 (fast drains at demo scale, default 300 slows
  every deploy), health check interval 30/unhealthy 3 (~90s eject), matcher 200-299,
  60s health-check grace only for ALB-attached services (slow Node boot).
- **Log groups created by Terraform** (not lazily by the awslogs driver) so 7-day
  retention is enforced — driver-created groups default to never-expire (cost leak).
- **Task role deliberately empty** (apps make no AWS calls; least privilege); execution
  role = managed AmazonECSTaskExecutionRolePolicy. Secrets (Phase 2) land on the
  EXECUTION role: injection happens before the app exists.
- **Skeleton image straight from Docker Hub** (weaveworksdemos/front-end:0.3.12) — the
  ECR mirror + :stable arrives with the Phase-3 pipeline (D8). Docker Hub pulls ride the
  NAT (tolled); post-mirror pulls ride the free S3 endpoint — a measurable cost argument.
- **Evidence recorded:** storefront serving 60s after apply; kill-task demo: ALB ejected
  the dead target in seconds, survivor carried traffic, self-heal to 2/2 in ~40s,
  availability 100% throughout (every 10s probe returned 200).

---

## Phase 2 — decisions made ahead of the build

### D10 — Secrets: SSM Parameter Store SecureString, not Secrets Manager
- **Decided:** application secrets (first one: the RDS MySQL password — the middle
  segment of catalogue's DSN `catalogue_user:PASSWORD@tcp(<rds-endpoint>:3306)/socksdb`)
  live in **AWS Systems Manager Parameter Store** as **SecureString** parameters
  (standard tier), injected into containers via ECS `valueFrom`.
- **What SSM is:** Systems Manager is an ops toolbox; the piece used here is Parameter
  Store — a key-value store for config and secrets. `SecureString` = encrypted at rest
  with KMS. Mapping: Azure Key Vault's role. Interview-grade contrast: **Kubernetes
  Secrets are base64-encoded, not encrypted by default — SSM SecureString is actually
  encrypted.**
- **Alternatives:** (a) AWS Secrets Manager — adds native rotation, cross-region
  replication, and RDS integration at **$0.40/secret/month**; the production
  recommendation when rotation is required (goes in docs). (b) Values in tfvars/env —
  violates the no-secrets-in-code agreement outright.
- **Why:** standard-tier Parameter Store is **free**, natively integrated with ECS
  secrets injection, and encrypted at rest — the full requirement at zero cost for a
  demo with no rotation requirement.
- **The mechanism (Phase 2 will implement exactly this):** Terraform generates the
  password → stores it as an SSM SecureString → catalogue's instantiation passes
  `secrets = { <ENV_NAME> = <parameter ARN> }` → the ecs-service module renders it into
  `valueFrom` in the task definition → at each task launch the **execution role** (not
  the task role — L14) calls SSM, decrypts via KMS, and injects the value as a plain
  env var inside the container. **Plaintext never appears in the task definition, the
  console, or git — the task def carries only the ARN.**
- **Honest caveat (say it before a reviewer does):** a Terraform-generated password
  also lives in the **Terraform state file** in S3 — encrypted at rest (AES256),
  versioned, public-access-blocked, single-user account. Known, accepted, documented
  trade-off; the stricter alternative (create the secret out-of-band and only reference
  its ARN) is noted for production.

### D12 — Service Connect: explicit bare dns_name + server-before-client ordering
- **Decided:** (a) every service's `client_alias` sets **`dns_name = <service name>` explicitly**
  — AWS defaults an omitted dnsName to `discoveryName.namespace` (e.g. `catalogue.sockshop`),
  which the images' baked-in bare hostnames can never match. (b) **Deploy order is code:**
  client modules carry `depends_on` on every service they call (front-end last; orders after
  its four peers; carts/user/shipping/queue-master after their data dependencies), because a
  Service Connect client's endpoint list is a **SNAPSHOT taken when its DEPLOYMENT is created**
  — AWS: "replacement tasks continue to behave the same as they did after the most recent
  deployment… you must redeploy existing services before the applications can resolve new
  endpoints." A *fresh task* is NOT a *fresh snapshot*.
- **How it was diagnosed (worth retelling in the defense):** all-green services + registered
  Cloud Map instances + running sidecars, yet ENOTFOUND. Ground truth came from a temporary
  SC-enabled "spy" task dumping /etc/hosts to CloudWatch (13 bare aliases present, full HTTP
  path working — including catalogue→RDS), then an impersonation task running the REAL
  front-end image (Node v4.8.0 resolved and connected perfectly — the 2017 runtime was
  innocent). Parallel doc research pinned the snapshot semantics. Root cause: orchestration
  ordering, not any component.
- **Operational rule derived:** when a Service Connect name won't resolve, compare the CLIENT
  service's last deployment time against the SERVER's registration time; if the client's
  deployment is older — `--force-new-deployment` the client. Added to the debugging ladder.

### D11 — SG chain completed; one amendment to the locked chain (session-db 6379)
- **Decided:** backend-sg (80 from frontend-sg + 80 from SELF — the self-reference
  covers every backend→backend pair: orders→carts/user/payment/shipping — in one
  membership-based rule), data-sg (27017 + 5672 from backend-sg), rds-sg (3306 from
  backend-sg). **Amendment:** data-sg additionally allows **6379 from frontend-sg** —
  session-db (Redis, accepted in D4) sits in the data tier but its only client is
  front-end, which the original locked chain (written pre-D4) didn't anticipate.
- **Why flagged:** CLAUDE.md marks the SG chain as locked; this is the D4 decision's
  mechanical consequence, surfaced explicitly rather than silently added. Everything
  else matches the locked chain exactly. Ports are exact, sources are SG-identities
  (never CIDRs inside the VPC), and the ONLY 0.0.0.0/0 ingress in the system remains
  alb-sg:80.
