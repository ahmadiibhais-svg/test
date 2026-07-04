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
- [L11 — Modules; the network module = L1 as code](#l11)
- [L12 — The ECS "cluster": a false friend; Service Connect; Container Insights](#l12)
- [L13 — Security groups + ALB anatomy](#l13)
- [L14 — ecs-service: the two roles, the pod-spec mapping, the circuit breaker](#l14)
- [L15 — Subnetting, the local route, and the full-picture diagram](#l15)
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

<a name="l11"></a>
## L11 — Modules; the network module = L1 as code

**A module is a Helm chart.** A folder of `.tf` files designed to be *called*, never
applied directly — no state, no backend, no life of its own. A root *instantiates* it:

| Helm | Terraform |
|---|---|
| chart (templates/) | module (folder of .tf) |
| values.yaml fields | the module's `variable` blocks |
| `helm install rel ./chart -f values` | `module "name" { source = … , var = … }` |
| chart outputs | the module's `output` blocks |

```hcl
module "network" {                      # keyword + ONE label (instance nickname)
  source     = "../../modules/network"  # the only special argument: folder path
  aws_region = var.aws_region           # everything else fills the module's variables
}
```

- Read a module's returns as `module.network.vpc_id` (reference rooted at `module.`).
- **init's 4th job: installing modules** (L9 listed three — this is the fourth).
  New module block → re-run `terraform init`.
- Modules inherit the root's `provider` config — no provider blocks inside modules.
- Module resources get namespaced addresses: `module.network.aws_vpc.this`. That prefix
  is why one root can call the same module 13× (ecs-service) without collisions.
- **Defense line:** "Modules are my charts: versioned units with typed inputs and outputs;
  environments are roots that compose them with different values."

**The network module, resource by resource (L1 as code):**

| Resource | L1 concept |
|---|---|
| `aws_vpc` 10.0.0.0/16, DNS on | the sealed box (DNS on because Service Connect + RDS hostnames need it) |
| 4 × `aws_subnet` (2 public, 2 private, across us-east-1a/b) | rooms; AZs = failure domains |
| `aws_internet_gateway` | the two-way inbound door |
| `aws_eip` + `aws_nat_gateway` in public-a | the outbound-only toll road (💰 ~$0.045/hr + $0.005/hr for the IPv4) |
| 2 × `aws_route_table` + 4 associations | what MAKES a subnet public/private |
| `aws_vpc_endpoint` Gateway/S3 on the private table | the free bypass for image layers |

**Key facts to articulate:**
- **"Public subnet" is not a checkbox.** It is route-table membership: associated table
  has `0.0.0.0/0 → IGW` = public; `0.0.0.0/0 → NAT` = private. Point at the exact block.
- **`depends_on`** (new meta-argument, same family as `lifecycle`): ordering normally
  comes from references (L2), but the NAT never *references* the IGW — yet can't function
  until the VPC has one. `depends_on = [aws_internet_gateway.this]` states a dependency
  the reference graph cannot see. Use it only for exactly this situation.
- **`map_public_ip_on_launch` stays false even on public subnets:** nothing there needs an
  automatic public IP (ALB manages its own, NAT has its EIP). Least surface everywhere.
- **One shared private route table** because one NAT; the multi-NAT production upgrade
  splits it into per-AZ tables, each pointing at its local NAT.
- Subnets written explicitly, no loop: at n=2, four named blocks beat a clever loop.
  Loops (for_each) earn their place at n=13 (ecs-service) — readability is a size decision.
- List indexing: `var.azs[0]` = first element of a list variable.

---

<a name="l12"></a>
## L12 — The ECS "cluster": a false friend; Service Connect; Container Insights

**"Cluster" is a false friend for K8s people.** K8s cluster = a control plane you operate
+ nodes that exist. ECS-with-Fargate cluster = neither: AWS runs the control plane
invisibly (no fee, no upgrades — part of the ECS-over-EKS rationale), and there are NO
nodes — each task gets its own right-sized micro-VM that exists only while the task runs.
What remains is a **logical boundary**: a named scheduling domain carrying default
settings and scoping monitoring.

**Defense line:** "An ECS/Fargate cluster is closer to a K8s namespace + scheduler config
than to a cluster — there is no infrastructure inside it until a task runs."

**The two resources:**
1. `aws_service_discovery_http_namespace` "sockshop" — the **CoreDNS role**: the registry
   where each service publishes its discovery name. front-end calling `http://catalogue/`
   resolves through this — ECS's analog of K8s Service DNS in a namespace. This is WHY
   discovery names must exactly match the hostnames baked into the images (locked list):
   the images offer no knob to change what they call.
2. `aws_ecs_cluster` with:
   - `setting { containerInsights = "enabled" }` — the **cAdvisor/metrics-server role**:
     per-service CPU/memory/task-count → CloudWatch. Phase 4 dashboards and Phase 5
     auto-scaling read these. 💰 bills as custom metrics (~$1–3/mo at our scale).
   - `service_connect_defaults { namespace = … }` — services created in the cluster join
     the namespace automatically.

**Also observed at apply time (unit 1):** the dependency choreography is visible in the
apply log — private route table waited on NAT (reference), NAT waited on IGW (explicit
depends_on), endpoint waited on the table. Nobody wrote that ordering; the graph did.
And: a follow-up plan does NOT touch already-applied resources — the diary knows them,
code matches reality, "0 to change." State doing its job.

**War story (real error we hit):** first-ever `CreateCluster` in the account failed with
"ECS Service Linked Role is not ready." A **service-linked role** is an IAM role a service
owns and manages for itself (`AWSServiceRoleForECS`), auto-created on the account's FIRST
use of the service — our first call both triggered its creation and raced it. Transient;
retry succeeded. Two lessons: (1) fresh accounts have first-touch races — pre-create SLRs
(`aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com`) or expect one
retry; (2) read the error before theorizing — it named its exact cause (it was NOT a
free-plan restriction). Bonus observed: the namespace had already succeeded and the retry
plan showed only "1 to add" — state recovering a partial failure exactly as designed.

---

<a name="l13"></a>
## L13 — Security groups + ALB anatomy

**Security group = stateful virtual firewall attached to a NETWORK INTERFACE** (not to a
subnet — that's NACLs). Contrast line: "NACLs guard the room, SGs guard the individual
sockets; my unit of security is the workload, not the subnet."

Two properties carry the whole security story:
1. **Stateful:** write rules only for the INITIATING direction; replies are auto-allowed.
   Rules read as "who may start a conversation with whom."
2. **SG-as-source:** a rule can name another security group instead of IPs — "allow 8079
   from anyone holding alb-sg." Identity-based, exactly a NetworkPolicy podSelector.
   Task IPs churn (scaling, failover, deploys); the rule never changes.

The least-privilege chain (each arrow = one ingress rule naming the previous group):
```
internet --80--> [alb-sg] --8079--> [frontend-sg] --80--> [backend-sg] --27017/5672--> [data-sg]
                                                              └--3306--> [rds-sg]
```
- alb-sg is the ONE place `0.0.0.0/0` is correct: it IS the public front door.
- Egress stays open everywhere; the chain is enforced on ingress (deliberate, standard,
  keeps the policy readable).

**ALB anatomy — three resources, three K8s roles:**

| Resource | K8s role | Decides |
|---|---|---|
| `aws_lb` | the Ingress controller appliance (managed, multi-AZ) | placement (public subnets), firewall (alb-sg) |
| `aws_lb_target_group` | EndpointSlice + readinessProbe | who gets traffic, and when they're healthy |
| `aws_lb_listener` | the Ingress rule | ":80 → forward to that group" |

Three arguments to articulate:
- **`target_type = "ip"`** — Fargate/awsvpc gives every task its own ENI + private IP
  (pod-IPs, literally), so the ALB targets IPs. `"instance"` is the NodePort-era pattern;
  there are no instances here.
- **`health_check { path = "/" }`** — ALB-side readinessProbe; fail 3× → out of rotation.
- **`deregistration_delay = 30`** — connection draining = terminationGracePeriod for
  in-flight requests: new traffic stops instantly, existing requests get 30s (default 300s
  = slow rollouts for nothing at demo scale).

Cross-module wiring appears here for the first time:
`vpc_id = module.network.vpc_id` — one chart's outputs feed the next chart's values; the
root is the composition layer. HTTPS/ACM = documented production upgrade, not in time box.

---

<a name="l14"></a>
## L14 — ecs-service: the two roles, the pod-spec mapping, the circuit breaker

**THE concept-pair (classic interview question): execution role vs task role.**

| | Execution role | Task role |
|---|---|---|
| Who uses it | the ECS PLATFORM, before/around the container | YOUR APP CODE, inside the container |
| For what | pull image from ECR, write CloudWatch logs, fetch+inject secrets | AWS API calls at runtime (S3, SQS, …) |
| K8s mapping | the kubelet's credentials | the pod's ServiceAccount (IRSA-style) |
| Failure signature | CannotPullContainerError, log failures | app logs AccessDenied at runtime |
| Ours | managed AmazonECSTaskExecutionRolePolicy | created but EMPTY (apps make no AWS calls) |

Diagnostic rule: **before-the-app failures → execution role; inside-the-app failures →
task role.** Defense line for the empty task role: "my apps call no AWS APIs, so their
runtime identity has zero permissions; Phase-2 secrets land on the EXECUTION role,
because injection happens before the app exists."

**The mapping table:**

| ECS piece | K8s equivalent |
|---|---|
| task definition | pod spec (immutable revisions) |
| service (`desired_count`) | Deployment (replicas; replaces dead tasks) |
| `network_configuration` | pod networking: private subnets, tier SG, `assign_public_ip=false` |
| `service_connect_configuration` | Service registration in DNS (port_name must match the portMapping name) |
| `deployment_circuit_breaker { rollback = true }` | rollout failure policy + AUTO-ROLLBACK: failing deploy halts and reverts to last working revision. THE rollback story (prod upgrade: CodeDeploy blue/green) |
| log group `/ecs/sockshop/<name>`, 7d | the log pipeline |

**Grammar met in this module:**
1. `jsonencode({...})` — HCL object → JSON string (container_definitions is historically
   a JSON-string field; also used for IAM trust policies).
2. for-expression `[for k, v in var.environment : { name = k, value = v }]` — reshape a
   friendly map into the API's list-of-objects (a list comprehension).
3. `dynamic "load_balancer" { for_each = … }` — render a nested block 0..N times; here
   0-or-1: only front-end passes a target group; 12 others render nothing.
4. Ternary `cond ? a : b` — ALB-attached services get 60s health-check grace, others null.

**Also:** tier SGs (frontend-sg…) live at the ROOT, not in a module — they are exactly
the wiring BETWEEN modules. One `module "front_end"` block → six resources: the leverage
that pays for the module 13×.

---

<a name="l15"></a>
## L15 — Subnetting, the local route, and the full-picture diagram

**CIDR:** `/N` = first N of 32 bits locked, rest free. `/16` = 65,536 addresses
(10.0.0.0–10.0.255.255); `/24` = 256 (AWS reserves 5 per subnet — network, router,
**DNS resolver at .2**, spare, broadcast — leaving 251 usable).

**The carving:** VPC owns the /16 (the estate — outer boundary, nothing lives in it
directly). Subnets are non-overlapping /24 plots: 10.0.0.0/24 public-a, 10.0.1.0/24
public-b, 10.0.10.0/24 private-a, 10.0.11.0/24 private-b. Gaps (2–9, 12+) = growth
without renumbering; "10.0.**10**.x = private tier" reads at a glance. Each Fargate task
consumes exactly one IP (its ENI). Oversizing the VPC is free; resizing later is pain.

**THE key fact — subnets need NO help talking to each other.** Every route table in a
VPC carries an immutable implicit route: `10.0.0.0/16 → local` = the VPC fabric. All
subnets are layer-3 adjacent, across AZs, always. IGW/NAT are ONLY for `0.0.0.0/0`
(unknown destinations) — "public/private" describes that one route and nothing else.
Control lives one layer up: **routing answers CAN it get there (in-VPC: always);
security groups answer MAY the connection be accepted (per ENI, per port, per
source-identity).** ALB→task works because `local` carries it AND frontend-sg permits
it. Delete the SG rule: still routed, dropped at the ENI.

**Defense line:** "Subnets don't need help talking — the local route makes the VPC
layer-3 adjacent; my SGs turn 'reachable' into 'allowed'."

**Line-level walkthrough highlights (the why-this-value layer):**
- `enable_dns_support` turns on the VPC resolver at 10.0.0.2; without it nothing inside
  resolves anything (ECR endpoints, SC names, RDS hostnames). `enable_dns_hostnames`
  issues names; the pair-true is the standard posture.
- NAT sits in public-a = the single-NAT trade-off IN CODE; must be in a public subnet
  (needs the IGW path).
- The 4 route_table_associations are what MAKE subnets public/private.
- S3 endpoint attached to the private table only — that's where image-layer traffic
  originates.
- TG health math: interval 30 × unhealthy 3 ≈ 90s to eject; healthy 2 ≈ 60s to admit;
  matcher 200-299 so redirects can't fake health.
- Log groups created BY Terraform so 7-day retention is enforced (driver-created groups
  default to never-expire).
- IAM trust policy (`assume_role_policy`) answers WHO MAY WEAR the role
  (ecs-tasks.amazonaws.com); the attached policy answers WHAT IT MAY DO.
- `family` = versioned task-def name; deploys mint revisions; the circuit breaker rolls
  back to the previous one.
- `desired_count` will be taken over by the Phase-5 autoscaler (lifecycle ignore_changes
  lands then).
- Tier SGs live at the ROOT (wiring between modules); alb-sg lives IN the alb module
  (belongs to the ALB).
- var.name quadruple duty (service/container/SC-name/log suffix) = locked-hostname rule
  enforced by construction.

**The diagram** (user → IGW → ALB[alb-sg] in public-a/b → :8079 → front-end tasks
[frontend-sg] with own ENIs in private-a/b → SC namespace "sockshop"; NAT+EIP in
public-a ← private RT 0/0; S3 prefix → gateway endpoint; outside the VPC: Docker Hub,
ECR API, CloudWatch via NAT; S3 layers via endpoint):

```
INTERNET → IGW → [ALB nodes, public-a/b, alb-sg :80]
                     │ :8079 (local route carries; frontend-sg permits src=alb-sg)
                     ▼
            [front-end tasks, private-a/b, own ENIs 10.0.10.x/10.0.11.x]
                     │ bare names via Service Connect "sockshop" (Phase 2: 12 more)
                     ▼
   egress: 0/0 → NAT (tolled) → Docker Hub/ECR API/CloudWatch
           S3 prefix → gateway endpoint (free) → S3 (image layers)

SG chain: world ─80→ alb-sg ─8079→ frontend-sg ─80→ backend-sg ─27017/5672→ data-sg
                                                        └─3306→ rds-sg   (Phase 2)
```

**Journey of a page load:** browser → ALB node (alb-sg :80) → healthy target either AZ →
local route → ENI :8079 (frontend-sg) → reply back same stateful path. IGW only at the
edge; NAT never.
**Journey of an image pull:** ENI → private RT → ECR auth/manifest via NAT (KB, tolled)
→ layers via S3 endpoint (MB, free). Docker Hub pulls ride NAT entirely — the Phase-3
ECR mirror fixes that cost.

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
8. Why does the NAT gateway carry an explicit `depends_on` when every other resource
   orders itself automatically? (L11)
9. What makes a subnet "public"? Point at the exact resource and line that decides it. (L11)
10. Why is `map_public_ip_on_launch` left false even on the public subnets? (L11)
11. "So how many nodes are in your ECS cluster?" — the trap question. Answer it. (L12)
12. Why must Service Connect discovery names exactly match the compose hostnames —
    where is the constraint actually coming from? (L12)
13. Why is the ALB's target group `target_type = "ip"` and not `"instance"`? (L13)
14. Your SG rules mostly name other SGs instead of CIDRs — why is that better here, and
    what's the K8s equivalent? (L13)
15. What does `deregistration_delay = 30` buy you during a deploy? (L13)
16. Your task pulls its image fine but the app gets AccessDenied calling S3 — which of
    the two roles is wrong, and why are you sure? (L14)
17. Walk me through what the deployment circuit breaker does when a bad image ships. (L14)
18. Why is the task role deliberately empty, and where will the Phase-2 secret permission
    land instead? (L14)
