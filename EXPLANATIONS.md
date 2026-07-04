# EXPLANATIONS — Ahmad's study notes (Terraform + AWS)

Every detailed lesson from the build sessions, organized for re-study before the defense.
Each lesson ends with **defense lines** — sentences to be able to say out loud, unprompted.
New lessons get appended as the project advances.

**Contents**
- [L1 — AWS networking: account ≠ network; NAT + S3 gateway endpoint](#l1)
- [L2 — HCL grammar: the four building blocks; anatomy of a resource](#l2)
- [L3 — data sources, interpolation, lifecycle meta-arguments](#l3)
- [L4 — State: Terraform's diary; local vs remote; the backend](#l4)
- [L5 — File names: what's magic, what's convention](#l5)
- [L6 — Image tags, mutability, digests](#l6)
- [L7 — Roots and outputs](#l7)
- [L8 — Terraform keywords reference](#l8)
- [L9 — The command lifecycle + our exact bootstrap chronology](#l9)
- [L10 — What goes to git vs what stays local](#l10)
- [Defense question bank](#defense-question-bank)

---

<a name="l1"></a>
## L1 — AWS networking: account ≠ network; NAT + S3 gateway endpoint

**The assumption to delete: "same AWS account = same network."** An account is a billing
and permissions boundary, not a network. Two separate layers, always:
- **IAM answers:** am I *allowed* to call this API? (auth)
- **Routing answers:** can my packets *physically reach* it? (reachability)

A task can have a perfect IAM role and still get `CannotPullContainerError` — permission
says nothing about there being a network path.

**Two kinds of "AWS things":**
1. Things AWS places **inside your VPC** with private IPs in your subnets: Fargate tasks,
   the RDS instance, the ALB. These talk to each other directly over VPC fabric — free,
   private, no NAT involved, ever.
2. Regional services that live **outside every VPC**: S3, ECR, CloudWatch, SSM, DynamoDB.
   They are multi-tenant utilities exposed via **public API endpoints** (public DNS + IPs,
   e.g. `api.ecr.us-east-1.amazonaws.com`) — the same endpoints your laptop hits.

"ECR is in my account" = permissions statement (my *repositories*).
"ECR is outside my VPC" = networking statement (the *service*). Both true.

**The VPC is a sealed box.** Nothing crosses its edge — in or out, not even to AWS's own
services — unless you build a door. K8s mapping: the VPC is the pod network; ECR is the
company Artifactory *outside* the cluster: same owner, still needs an egress path.

**The doors:**
- **Internet Gateway (IGW)** — the public subnets' two-way door (used by ALB inbound).
- **NAT gateway** — the private subnets' *outbound-only* door. Sits in a public subnet
  with a public IP; rewrites outbound packets' source, relays replies. Home-router logic:
  everyone inside can browse out; nobody outside can initiate in.
- **VPC endpoints** — private doors to *specific AWS services* (the "magic connectivity"
  you'd expect to exist — it does, as an opt-in feature). Two flavors:
  - **Gateway endpoint** (S3 + DynamoDB only): a route-table entry. **Free.**
  - **Interface endpoint** (nearly everything else): an ENI with a private IP in your
    subnet. ~$7.30/month each + per-GB.
- "S3 gateway endpoint" = "gateway VPC endpoint for S3" — one object, two word orders.

**We use NAT *and* the S3 gateway endpoint — different destinations, not competitors.**
The private route table encodes it (most-specific route wins):

```
10.0.0.0/16     → local        (tasks↔tasks, tasks↔RDS — free)
S3 prefix list  → vpce-xxxx    (S3 traffic — free)
0.0.0.0/0       → nat-xxxx     (everything else — tolled)
```

**Anatomy of one image pull** (the trick: ECR stores image *layers* in S3):
1. Task → ECR API: auth + "where's the manifest?" — KILOBYTES — via NAT (tolled).
2. ECR: "layers are at these S3 URLs."
3. Task → S3: download layers — HUNDREDS OF MB — via gateway endpoint (**free**).

The endpoint diverts ~99% of the *bytes* at $0.

**Decoding "free, no per-GB toll, never leaves AWS's network":** gateway endpoints have no
hourly and no data fee (NAT: $0.045/hr + $0.045/GB). Precise version of the last clause:
via the endpoint the path contains **no public IPs, no NAT hop, no IGW at all** — and the
subnet needs no public egress path for S3 to work. (Even NAT-path traffic to same-region
AWS services rides AWS's backbone; the differences that matter are the toll and the
dependency on NAT.) For non-AWS destinations (Docker Hub, GitHub) NAT traffic genuinely
goes to the internet.

**Traffic map of our architecture:**

| Traffic | Path | Cost |
|---|---|---|
| User → storefront | Internet → IGW → ALB → front-end | ALB hourly/LCU |
| Task ↔ task, task ↔ RDS | VPC-internal, private IPs | Free — NAT never involved |
| Task → S3 (image layers) | Gateway endpoint | Free |
| Task → ECR API / CW Logs / SSM | NAT | $0.045/GB (tiny volumes) |
| Task → Docker Hub / GitHub | NAT → internet | $0.045/GB |

**Why not delete NAT and go 100% endpoints?** 3 interface endpoints ≈ $22/mo ≈ one NAT,
and we still need real-internet egress (Docker Hub, GitHub) anyway. Endpoint-vs-NAT is a
per-traffic-class cost decision, not dogma. Honest caveat: if NAT's AZ dies, image pulls
still break (step 1 rides NAT) — the S3 endpoint is a **cost** optimization, not an
availability fix. Single NAT = documented trade-off; the *serving* path (ALB → tasks)
stays multi-AZ; prod = one NAT per AZ.

**Defense lines:**
- "An AWS account is a permissions boundary, not a network. IAM says whether I may;
  routing says whether I can."
- "S3 and ECR aren't in my VPC — they're public regional endpoints. My VPC is sealed, so
  I built two doors: a free gateway endpoint for the heavy S3 bytes, NAT for the thin rest."
- "Service-to-service traffic never touches NAT — it's private VPC fabric. NAT is only for
  AWS APIs and the public internet."
- "Single NAT halves egress cost and only risks the egress path; production gets one per AZ."

---

<a name="l2"></a>
## L2 — HCL grammar: the four building blocks; anatomy of a resource

Everything in any `.tf` file is one of four things:
1. **Blocks** — keyword + `{ ... }`
2. **Labels** — quoted strings between keyword and `{`
3. **Arguments** — `name = value` lines inside a block
4. **Nested blocks** — a block inside a block (grouped settings)

```
resource "aws_s3_bucket_versioning" "tf_state" {
│         │                          │
│         │                          └── LABEL 2: nickname — WE invented it; never
│         │                              leaves our code; exists so other lines can
│         │                              point at this block (like metadata.name)
│         └───────────────────────────── LABEL 1: resource TYPE from the provider's
│                                        catalog (aws + s3_bucket + versioning);
│                                        like kind: Deployment
└─────────────────────────────────────── keyword: "create and manage a real thing"
```

- The two labels form the block's **address**: `aws_s3_bucket_versioning.tf_state`.
- **Argument** names come from the type's schema (docs), like `spec.replicas` — you can't
  rename them. Values you choose.
- **References** are unquoted paths: `aws_s3_bucket.tf_state.id` = type → nickname →
  attribute ("the id AWS assigned after creating it"). For S3 buckets, `id` = bucket name.
- **References create ordering.** Terraform builds a dependency graph from them — the
  bucket is created before its versioning, and nobody wrote that ordering by hand.
  K8s contrast: K8s controllers retry until dependencies appear; Terraform computes the
  order up front.
- **Nested blocks** mirror the AWS API's own sub-structures
  (`versioning_configuration { status = "Enabled" }`).
- `status` is a string, not a boolean, because the API has three states: `Enabled`,
  `Suspended`, never-enabled. Once enabled, a bucket can never return to "never" — only
  Suspended.
- **Nicknames only need to be unique per type** — `aws_s3_bucket.tf_state` and
  `aws_s3_bucket_versioning.tf_state` coexist like same-named files in different folders.
  Reusing a nickname across related resources is a style that says "one logical thing."
- Why is versioning a separate resource instead of a setting on the bucket? The provider
  decomposed the old mono-bucket resource (v4+) — each aspect independently managed,
  smaller blast radius per change.

**Defense line:** "This resource enables versioning on the state bucket — referencing the
bucket by address, which also tells Terraform to create the bucket first — because state
is the one file whose history I must be able to restore."

---

<a name="l3"></a>
## L3 — data sources, interpolation, lifecycle meta-arguments

```hcl
data "aws_caller_identity" "current" {}
```
- **`resource` = "create and manage this." `data` = "just look this up; it's not mine."**
  This one asks AWS "who am I?" (account ID, ARN). Empty body = no settings needed.
- Data-source addresses start with `data.`:
  `data.aws_caller_identity.current.account_id`.

```hcl
bucket = "avertra-sockshop-tfstate-${data.aws_caller_identity.current.account_id}"
```
- **`${ ... }` = interpolation**: paste a computed value into text. Used here because S3
  bucket names are globally unique across ALL AWS accounts — the account-ID suffix
  guarantees no collision without hard-coding.

```hcl
lifecycle {
  prevent_destroy = true
}
```
- `lifecycle` is a **meta-argument block**: not from the S3 schema — Terraform itself
  understands it on ANY resource (same family as `for_each`).
- `prevent_destroy = true`: any plan that would delete this resource **fails to plan**.
  Interlock against our own tooling only — it does NOT stop a human deleting in the
  console.

---

<a name="l4"></a>
## L4 — State: Terraform's diary; local vs remote; the backend

**State is a JSON file — Terraform's diary.** One entry per managed resource, mapping
**code address → real AWS ID**:

```json
{ "type": "aws_s3_bucket", "name": "tf_state",
  "instances": [{ "attributes": { "id": "avertra-sockshop-tfstate-448049810701", ... } }] }
```

Read: "the block my code calls `aws_s3_bucket.tf_state` is, in the real world, bucket
`avertra-sockshop-tfstate-…`." That mapping is how `plan` can say "0 to change" — it
compares code vs diary vs real AWS. Delete the diary → amnesia → plan wants to create
everything again (even though it exists). K8s parallel: the diary plays etcd's role.

- **Local state** = the diary is a file on your laptop (`bootstrap/terraform.tfstate`).
  Default when nothing says otherwise.
- **Remote state** = the diary is an object in S3. You get it ONLY by writing a
  `backend "s3" { ... }` block (terraform/envs/dev/backend.tf has one; bootstrap has none).

**What a root BUILDS ≠ where it KEEPS ITS NOTES.** Bootstrap *manufactures* the bucket as
a product; its own notes stay local. The safe factory can't store the blueprint for the
first safe inside that safe — it didn't exist yet (the chicken-and-egg).

```
bootstrap/  (factory)                    terraform/envs/dev/
BUILDS: bucket, 13 ECR, budget           BUILDS (Phase 1+): VPC, ECS, ALB, RDS…
DIARY:  bootstrap/terraform.tfstate      DIARY: s3://avertra-sockshop-tfstate-…/
        (file on YOUR laptop)                   envs/dev/terraform.tfstate
```

**Why remote for the main root:**
1. **The pipeline (the real reason):** Phase 3 runs terraform on GitLab's runners — a
   fresh machine every time. A laptop-local diary would give runners amnesia. Remote
   state = shared diary for you + runners + future teammates.
2. **Locking:** `use_lockfile = true` → S3 holds a lock object during writes; one writer
   at a time (like leader election). Native since TF 1.10 — the DynamoDB lock table you
   see in old tutorials is obsolete.
3. **Survival:** laptop dies → dev diary safe in S3 (versioned + encrypted).

Bootstrap stays local because it's tiny, applied once by a human, never pipeline-run;
worst case, 31 static resources are re-attachable via `terraform import` (accepted risk,
D7).

---

<a name="l5"></a>
## L5 — File names: what's magic, what's convention

**Terraform reads a DIRECTORY, not files.** It glues every `.tf` file in the folder into
one document; names are for humans. `backend.tf` isn't found by its name — the
`terraform { backend "s3" {} }` BLOCK is found wherever it lives.

Convention (like deployment.yaml/service.yaml — kubectl doesn't care either):

| File | Conventionally holds |
|---|---|
| versions.tf | `terraform {}` block: engine + provider pins |
| providers.tf | `provider "aws" {}` configuration |
| variables.tf | all `variable` blocks (inputs) |
| outputs.tf | all `output` blocks (published results) |
| main.tf | the resources, when few |
| (ours) state-bucket.tf, ecr.tf, budget.tf, backend.tf | resources split by topic — readability |

**Actually magic (exact spelling changes behavior):**

| Name | Why |
|---|---|
| `.tf` extension | only these files are read at all |
| **`terraform.tfvars`** | **auto-loaded variable VALUES** (why the email applied with no flags) |
| `*.auto.tfvars` | also auto-loaded |
| `.terraform/` | created by `init`: provider plugins + backend wiring; never edit/commit |
| `.terraform.lock.hcl` | created by `init`: exact provider versions (like package-lock.json); **committed** |
| `terraform.tfstate` | default local diary name when no backend block exists |

**Defense line:** "File names are convention except tfvars and the lock file; the unit of
code is the directory, and blocks can live anywhere within it."

---

<a name="l6"></a>
## L6 — Image tags, mutability, digests

**Git mapping (exact, not approximate):**
- Image = content blob with a derived fingerprint (**digest**, `sha256:…`) = **commit + hash**.
- Tag (`front-end:0.3.12`) = named pointer to a blob = **branch name**.
- Moving a mutable tag = `git branch -f stable abc123`.
- Immutable tag = git tag by convention: minted once, never reused.
- Pin by digest (`image@sha256:…`) = referencing the commit hash itself — the ultimate
  exact reference.

**The digest is DERIVED, not attached.** It's the sha256 *of the image's bytes* — like a
commit hash, it isn't a sticker someone applied; it's arithmetic on the content. Same
bytes → same digest, everywhere, forever. **Tagging/untagging/re-tagging never touches
it** — tags are just rows in the registry's lookup table (name → digest). An image with
zero tags ("untagged") still exists and is still pullable by digest. That's exactly what
our ECR janitor rule cleans: when pointers move away and nothing names a blob anymore,
it's expired after 7 days (it still bills storage otherwise).

**ECR's `image_tag_mutability` policy:**
- `MUTABLE` (ours): pushing an existing tag name is allowed — the pointer moves.
- `IMMUTABLE`: pushing an existing tag name is **rejected**.

**The Phase-3 pipeline flow this enables** (GitLab CI, per service):
```
1. docker pull weaveworksdemos/front-end:0.3.12      (upstream, Docker Hub)
2. trivy image …                                     (scan; CRITICAL = stop)
3. docker push <ecr>/sockshop/front-end:a1b2c3d      (unique commit-SHA tag — audit)
4. docker push <ecr>/sockshop/front-end:stable       (movable "current good" pointer)
5. aws ecs update-service --force-new-deployment     (ECS re-pulls :stable, rolls tasks)
```
Task definitions permanently say `:stable`; deploying = re-pointing + re-rolling.

**Why IMMUTABLE is the stricter production pattern** (D8):
1. Audit: with `:stable`, the task def doesn't identify the bytes; unique tags ARE the record.
2. Rollback: re-point-and-trust vs point-back-at-exact-known-blob.
3. Security: stolen registry creds + mutable tag = silently swap what `:stable` means.

**Defense line:** "I run mutable `:stable` plus a unique SHA tag per push — fast to build,
with an audit trail. In production I'd flip ECR to IMMUTABLE and drive the exact tag or
digest through Terraform: every deploy a reviewable diff, every rollback exact."

---

<a name="l7"></a>
## L7 — Roots and outputs

**A root = a directory where you run `terraform init/plan/apply`.** The unit of execution.
**Each root owns exactly one state diary.** Our repo has exactly two roots:

```
bootstrap/            root #1 — applied once, local diary
terraform/envs/dev/   root #2 — everything else, diary in S3
terraform/modules/*   NOT roots — reusable "charts" root #2 will call (Phase 1)
```

Two roots = two sealed universes; root #2 has no idea bootstrap exists.

```hcl
output "tf_state_bucket" {          # keyword + NAME we chose
  description = "…"                 # label for humans
  value       = aws_s3_bucket.tf_state.bucket   # a reference (L2 grammar)
}
```
After apply, Terraform evaluates outputs, prints them, and records them in the diary;
`terraform output` re-reads them anytime.

**Why:** a root builds many internal things; outputs are the few values it *publishes* —
the shop window. Bootstrap publishes exactly two facts:
1. **the bucket name** → hand-copied into root #2's backend block (by hand *because*
   backends evaluate at init, before references exist — L5/L9);
2. **the 13 ECR repo URLs** → will be injected into the Phase-3 CI job ("where do I push?").

---

<a name="l8"></a>
## L8 — Terraform keywords reference (all we've met)

| Keyword | Declares | Our examples | Referenced as |
|---|---|---|---|
| `terraform {}` | Settings about the TOOL itself (not AWS): engine pin, plugin list, backend | versions.tf, backend.tf | (not referenced) |
| `required_providers` | *Nested inside `terraform{}`*: the plugin shopping list — source + version per provider | versions.tf | (read by `init`) |
| `provider "aws" {}` | CONFIGURES the downloaded plugin: region, default_tags, creds chain | providers.tf | (implicit for all aws_* resources) |
| `resource` | A real thing to create/manage/destroy | bucket, ECR repos, budget | `type.nickname.attr` |
| `data` | A read-only lookup of something NOT ours | caller identity | `data.type.nickname.attr` |
| `variable` | An input (the root's values.yaml field) | region, emails, repo list | `var.name` |
| `output` | A published result | bucket name, repo URLs | `terraform output` |

The pair to never confuse: **`required_providers` = which driver + version to install;
`provider` = how to configure the installed driver.** (Buy the engine vs tune it.)
Coming later: `module` (Phase 1), `locals`.

---

<a name="l9"></a>
## L9 — The command lifecycle + our exact bootstrap chronology

`terraform` is a CLI with subcommands. The lifecycle:

| Command | What it does | Touches AWS? |
|---|---|---|
| `terraform fmt` | Rewrites files into canonical formatting (like gofmt) | No |
| `terraform init` | (1) reads `required_providers`, downloads plugins into `.terraform/`; (2) writes/checks `.terraform.lock.hcl`; (3) configures the backend — local or S3 — and connects to existing state | Only the backend (S3), no resources |
| `terraform validate` | Static check: syntax, references resolve, argument names exist | No |
| `terraform plan -out=plan.tfplan` | 3-way diff (code vs diary vs reality) → proposed changes, frozen into a binary file | Read-only |
| `terraform apply plan.tfplan` | Execute EXACTLY the frozen plan; update the diary; print outputs | **Yes — creates/changes** |
| `terraform destroy` | Plan+apply whose goal is "nothing exists" | **Yes — deletes** |

**Files come FIRST, init second — always.** Init cannot know what to download until a
`.tf` file declares `required_providers`. (Ahmad inferred this himself. Correct.)

**Exact chronology used for this repo:**
```
bootstrap/:
 1. wrote the files: versions.tf, providers.tf, variables.tf, state-bucket.tf,
    ecr.tf, budget.tf, outputs.tf, terraform.tfvars(.example)      [just text]
 2. terraform fmt                                                  [formatting]
 3. terraform init        → downloaded aws provider 6.x, wrote lock file,
                            no backend block → local diary
 4. terraform validate    → "Success! The configuration is valid."
 5. terraform plan -out=plan.tfplan   → "31 to add, 0 change, 0 destroy"
 6. (email changed → re-ran plan; guard: still exactly 31/0/0)
 7. terraform apply plan.tfplan       → 31 created; terraform.tfstate written;
                                        outputs printed
terraform/envs/dev/:
 8. wrote versions.tf, backend.tf, providers.tf, variables.tf
 9. terraform init        → THIS time a backend block exists → connected to the
                            S3 bucket; provider downloaded for this root too
```

A saved plan **freezes everything** (including variable values) — change anything, re-plan.
That freeze is what makes the plan→approve→apply gate trustworthy.

---

<a name="l10"></a>
## L10 — What goes to git vs what stays local

"Bootstrap's diary is local" does NOT mean bootstrap is ignored by git — the **code** is
committed; the **diary and caches** are not:

```
bootstrap/
├── *.tf                      ✓ committed (the code — the whole point of IaC)
├── terraform.tfvars.example  ✓ committed (placeholder values)
├── .terraform.lock.hcl       ✓ committed (exact plugin versions for every machine)
├── terraform.tfvars          ✗ ignored (real values / personal data)
├── terraform.tfstate         ✗ ignored (the diary — may contain sensitive attributes;
│                                        belongs to exactly one place, git history of
│                                        state = chaos)
├── plan.tfplan               ✗ ignored (transient artifact)
└── .terraform/               ✗ ignored (downloaded plugins cache)
```

Rule of thumb: **commit declarations, ignore records and caches.**

---

## Defense question bank

1. Why does bootstrap keep local state while the main root uses S3 — and what breaks if
   you flip that? (L4)
2. `for_each` vs `count` for the 13 ECR repos — what happens under each when a service is
   removed from the middle of the list? (ecr.tf lesson — pending deep dive)
3. The single NAT's AZ dies. What keeps working, what degrades, why acceptable? (L1)
4. Why both ACTUAL and FORECASTED budget alerts? (budget.tf)
5. Warm-up: which rows of the L1 traffic map change if we adopt interface endpoints?
6. Why is `terraform.tfvars` gitignored but `.terraform.lock.hcl` committed? (L5/L10)
7. What exactly does a saved plan file freeze, and why does that make the approval gate
   trustworthy? (L9)
