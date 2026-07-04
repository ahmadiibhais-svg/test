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
