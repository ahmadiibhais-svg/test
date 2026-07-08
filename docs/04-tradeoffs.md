# 04 — Trade-offs & Considerations

Nothing in this build is accidental. Every compromise below was made consciously and priced against its alternative; the production upgrades live in [05-production-roadmap.md](05-production-roadmap.md).

## Platform & compute

| Decision | Chose | Instead of | Why |
|---|---|---|---|
| Orchestrator | ECS on Fargate | EKS | Same required outcomes (HA, scaling, fault tolerance) with no control-plane fee, no node operations, and apply cycles in minutes — decisive in a time-boxed build |
| Launch type | Fargate | ECS on EC2 | Zero node management; hard per-task VM isolation. Accepted cost: task size = request, limit, and bill in one number — no overcommit, no burst |
| NAT | One gateway | One per AZ | ~$1/day each; an AZ loss here degrades egress only, never inbound service |

## Network & exposure

| Decision | Chose | Instead of | Why |
|---|---|---|---|
| Ingress protocol | HTTP :80 | HTTPS/ACM | Time box; no real user data |
| Private egress | Free S3 gateway endpoint only | + paid interface endpoints | The endpoint carries the heavy leg (image layers) for free; the remaining API calls are kilobytes through NAT |
| SG granularity | Tier-level groups | Per-service groups | Five groups instead of thirteen; the permission envelope is slightly wider than the call graph (all backends *may* reach RDS; only catalogue does) |
| Egress rules | Open | Egress allow-lists | Security groups are stateful; the chain is fully enforced on who may *initiate*, and pulls/secrets/logs all originate outbound |

## Data & state

| Decision | Chose | Instead of | Why |
|---|---|---|---|
| Relational tier | RDS MySQL (Multi-AZ **enabled** for the assessed environment) | catalogue-db container | Containers can't provide failover without real replication engineering; RDS delivers it behind a flag, plus backups — and satisfies the "databases" requirement properly, once, as the pattern |
| Mongo ×3 / Redis / RabbitMQ | Ephemeral containers, **no authentication**, network-fenced | Managed equivalents | No free tier (DocumentDB alone ≈ $55+/month/instance ×3); the demo data is disposable; the SG chain is the only client path |
| DB identity | Master user for both seed and catalogue | Dedicated least-privilege DB account | Kept it to a single credential — a dedicated read-only DB user is the right practice, but setting one up wasn't worth the time here |
| Terraform partitioning | Two roots (bootstrap / dev) | One root | Bootstrap (state bucket, ECR, OIDC, budget) must survive the continues destroy; a root is a blast-radius boundary |

## Identity & pipeline

| Decision | Chose | Instead of | Why |
|---|---|---|---|
| CI credentials | OIDC federation — zero stored secrets | IAM user keys in CI variables | Platform-asserted identity per job, one-hour credentials, trust pinned to the **immutable project ID**; a leak dies in minutes |
| Image tagging | Mutable `:stable` + explicit `deploy` job | Immutable SHA threaded through Terraform | Shipping a new image doesn't touch any Terraform, so app releases skip the plan-review-apply gate entirely — one button redeploys. The cost: because nothing in the code changed, Terraform can't see releases, so a separate deploy step has to tell ECS to pull the new image. |
| Runners | GitLab SaaS | Self-hosted in the VPC | Deploys need credentials, not network proximity; a self-hosted runner is a second suspect in every failure + time-box |

## Scanning & supply chain

| Decision | Chose | Instead of | Why |
|---|---|---|---|
| Image path | Mirror through ECR (pull → Trivy → push) | Task defs referencing Docker Hub | Chain of custody (what was scanned is byte-for-byte what deploys — Hub tags are mutable); task launches (self-healing, scale-out) must not depend on a rate-limited third-party registry hosting an *archived* project; ECR layers ride the free endpoint |

## Observability & operations

| Decision | Chose | Instead of | Why |
|---|---|---|---|
| Third pillar | Metrics + logs; **no traces** | X-Ray/ADOT | The 2017 binaries can't be agent-instrumented without rebuilds; Service Connect's Envoy provides per-connection telemetry in the meantime |
| Hang detection | ALB health checks on front-end only | Container health checks ×13 | ECS container probes are exec-only — they need a shell and an HTTP client *inside* the image; several Go images are scratch-built with neither. Crash-healing is free everywhere (`essential = true`) |
| Log retention | 7 days, Terraform-managed | Driver-created groups | Driver-created log groups default to never-expire — a silent cost leak |
| Drift remediation | Deliberately human (revert or codify through the gated apply) | Scheduled auto-apply | Auto-revert would happily re-break production by undoing an incident fix it cannot understand; drift is information, not noise |

## Incidents & lessons that shaped these decisions

The most defensible parts of this build are the ones that broke first.

- **The name-resolution hunt.** All thirteen services deployed green, and the storefront insisted `catalogue` didn't exist. Root cause, twice over: an omitted Service Connect `dns_name` defaults to `name.namespace`, while the 2017 binaries dial bare hostnames; and endpoint snapshots are taken **per deployment, not per task** — "a fresh task is not a fresh deployment." The fixes are now structure: explicit `dns_name`, deploy ordering that mirrors the call graph, and the deploy job's forced new deployments.
- **MySQL 8's handshake vs a 2017 driver.** The engine's default auth plugin postdates catalogue's driver; the server-level parameter is immutable on RDS (the parameter-group fix was rejected at apply); the solution is account-level — the seeding task's *modern* client runs `ALTER USER … mysql_native_password` before catalogue ever connects.
- **A recycled name almost broke the trust policy.** GitLab refuses path-based OIDC subjects for namespaces with a prior life; trust is pinned to the immutable numeric project ID instead. The rule appears throughout this build: bind trust to immutable identifiers — security-group identity over IPs, project IDs over paths, digests over tags.
- **First contact with ECS raced AWS itself.** The account's first-ever cluster creation failed once with "Service Linked Role is not ready" — role creation outlasted Terraform's built-in retry window; a manual retry succeeded. One-time per account.

---

*Next: [05-production-roadmap.md](05-production-roadmap.md).*
