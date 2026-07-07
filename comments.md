# comments.md — annotation reference

The narrative annotations for this codebase, consolidated from inline position into
one reference document. Each entry carries the original comment text and the code
lines it explains, grouped by file in original order. Companions: DECISIONS.md (the
decision log) and EXPLANATIONS.md (the study lessons). Functional directives
(#tfsec:ignore lines and .trivyignore) remain in the code, where their tools read them.

---

## .gitlab-ci.yml — seed & load-demo jobs (added 2026-07-07)

### why the seed job exists and how it judges itself
> Automates the post-rebuild seeding ritual: looks up the CURRENT private subnets and
> backend-sg by tag/name (fresh IDs every rebuild), fires the sockshop-seed task
> (K8s-Job pattern), waits for it to stop, then reads the task's own CloudWatch logs
> back into the job log. The final grep IS the gate: no "SEED COMPLETE" in the logs,
> no green job — a seed that can't prove it worked is treated as failed. Production
> upgrade path: replace dump.sql with Liquibase changesets run by the same
> pipeline-orchestrates/VPC-executes pattern (the runner can never reach the private
> RDS directly).

```yaml
seed:
  ...
  - grep -q "SEED COMPLETE" seed.log
```

### why load-demo takes variables and doesn't wait
> CLIENTS/REQUESTS are job variables so demo intensity is a form field at trigger
> time (defaults = the proven siege: 10 clients, 10000 total requests, roughly 5-6
> minutes). The job fires the user-sim task and exits green immediately — the
> "result" of a load test is watched on the ECS service page and the CloudWatch
> dashboard, not in a job log; holding a runner hostage for 6 minutes would prove
> nothing.

```yaml
load-demo:
  variables:
    CLIENTS: "10"
    REQUESTS: "10000"
```

### load-stop — the off-switch (Ahmad's design call, 2026-07-07)
> The symmetric twin of load-demo: finds any RUNNING user-sim task and stop-tasks it —
> locust dies instantly, traffic ceases, the autoscaler walks capacity back to baseline
> on its own schedule. load-demo stays safe to keep in the pipeline because it is
> manual-only, finite (-r is a request BUDGET, self-terminating), and capped by the
> scaler's max — but a fireable test deserves a stop button. Production note: real load
> tests belong to a perf environment via a separate pipeline, never the prod deploy one.

```yaml
load-stop:
  ...
  - for T in $TASKS; do aws ecs stop-task ...
```

---

# Migrated comments — batch A (bootstrap/ + .gitignore)

## bootstrap/versions.tf

### file purpose: version constraints
> Terraform and provider version constraints.

```hcl
terraform {
```

### why Terraform >= 1.10 (native S3 lockfile)
> >= 1.10 gives the main root the native S3 state lockfile (`use_lockfile`), so this project needs no DynamoDB lock table at all.

```hcl
  required_version = ">= 1.10"
```

### why the AWS provider major version is pinned
> Pin the major version (like pinning a Helm chart major): breaking changes arrive in majors; "~> 6.0" means any 6.x, never 7.

```hcl
      version = "~> 6.0"
```

## bootstrap/providers.tf

### why default_tags on every resource
> Stamped onto every resource this root creates — the K8s-labels-on-every-object habit. Makes project resources findable in the console and in Cost Explorer.

```hcl
  default_tags {
    tags = {
      Project   = "avertra-sockshop"
```

## bootstrap/state-bucket.tf

### file purpose + why bootstrap keeps local state (chicken-and-egg)
> S3 bucket that will hold Terraform state for the main root.
>
> Chicken-and-egg note: the bucket that stores state cannot store the state of its own creation — so THIS root keeps local state. Acceptable because bootstrap is tiny, applied once, and never part of the nightly destroy (DECISIONS.md D7).

```hcl
data "aws_caller_identity" "current" {}
```

### why the account ID is suffixed onto the bucket name
> Bucket names are globally unique across ALL AWS accounts; suffixing the account ID guarantees uniqueness (account IDs are not secret — they appear in every ARN).

```hcl
  bucket = "avertra-sockshop-tfstate-${data.aws_caller_identity.current.account_id}"
```

### why prevent_destroy on the state bucket
> Hard refusal to destroy the resource that holds every other stack's memory.

```hcl
  lifecycle {
    prevent_destroy = true
  }
```

### why versioning is enabled (state undo history)
> Versioning = undo history for state. A corrupted or mis-written state file can be rolled back to any prior version — insurance that costs kilobytes.

```hcl
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
```

### why state is encrypted at rest with SSE-S3
> State files contain resource attributes (endpoints, ARNs, generated values) — encrypt at rest with the free S3-managed key (SSE-S3 / AES256).

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
```

### why all public access is blocked
> Belt-and-braces: block every form of public access (ACL- and policy-based, present and future). State must never be publicly readable.

```hcl
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
```

## bootstrap/ecr.tf

### file purpose + for_each as the Helm-range analog
> One ECR repository per service (13 — see var.ecr_repositories / SERVICES.md).
>
> for_each over a set is Terraform's Helm-`range` analog: one resource instance per name, individually addressable as aws_ecr_repository.services["front-end"].

```hcl
resource "aws_ecr_repository" "services" {
  for_each = toset(var.ecr_repositories)
```

### why scan_on_push (first scanning layer)
> ECR's built-in vulnerability scan on every push — the first scanning layer (pipeline Trivy is the second). Findings surface per-image in the console.

```hcl
  image_scanning_configuration {
    scan_on_push = true
  }
```

### why image tags are MUTABLE (documented trade-off)
> MUTABLE because the pipeline re-points a `stable` tag on each deploy. Documented trade-off: immutable tags driven through Terraform are the stricter production pattern (see docs, Phase 3).

```hcl
  image_tag_mutability = "MUTABLE"
```

### why the untagged-image lifecycle policy exists
> Re-pushing tags leaves untagged layer sets behind, and they still bill storage ($0.10/GB-month). Expire them automatically after 7 days.

```hcl
resource "aws_ecr_lifecycle_policy" "expire_untagged" {
  for_each = aws_ecr_repository.services
```

## bootstrap/budget.tf

### file purpose: budget as code, four explicit notification blocks
> The $25/month cost guardrail (CLAUDE.md), managed as code like everything else. (The hand-made "My Budget" ($40/daily) from account setup is left untouched; this one is the project guardrail — DECISIONS.md D7.)
>
> Four explicit notification blocks instead of a dynamic loop: this is a guardrail, and guardrails should be boringly readable.

```hcl
resource "aws_budgets_budget" "monthly" {
  name        = "avertra-sockshop-monthly"
  budget_type = "COST"
```

### 50% notification: early warning
> Early warning: half the budget actually spent.

```hcl
  notification {
    notification_type          = "ACTUAL"
    threshold                  = 50
```

### 80% notification: time to scale down
> Second warning: 80% actually spent — time to scale things down.

```hcl
  notification {
    notification_type          = "ACTUAL"
    threshold                  = 80
```

### 100% notification: budget breached
> Budget breached in fact.

```hcl
  notification {
    notification_type          = "ACTUAL"
    threshold                  = 100
```

### forecast notification: fires before the money is gone
> Trend-based: AWS forecasts month-end spend will exceed the budget — fires days before the money is actually gone (e.g. a NAT gateway left running).

```hcl
  notification {
    notification_type          = "FORECASTED"
    threshold                  = 100
```

## bootstrap/oidc.tf

### file purpose: GitLab->AWS OIDC federation, zero stored credentials
> GitLab CI -> AWS via OIDC federation (deferred in D7, delivered in Phase 3 / D13). The pipeline holds ZERO long-lived AWS credentials: each job presents a GitLab-signed identity token (a passport), AWS checks issuer + project path (border control), and STS hands out ~1h temporary credentials. Same pattern as IRSA in EKS, with gitlab.com as the issuer.

```hcl
resource "aws_iam_openid_connect_provider" "gitlab" {
  url = "https://gitlab.com"
```

### the OIDC provider is the trusted passport issuer
> The trusted passport issuer.

```hcl
resource "aws_iam_openid_connect_provider" "gitlab" {
```

### what client_id_list is (the aud claim)
> The "aud" claim our CI tokens will carry (set in .gitlab-ci.yml id_tokens).

```hcl
  client_id_list = ["https://gitlab.com"]
```

### why the thumbprint field exists and where the value came from
> Legacy-required field: AWS now validates gitlab.com against its own trusted CA store and largely ignores this, but the API demands a value. Root-CA SHA1 fetched live via openssl on 2026-07-05.

```hcl
  thumbprint_list = ["d89e3bd43d5d909b47a18977aa9d5ce36cee184c"]
```

### role trust conditions: pinned by immutable project ID, not path
> The role a passport-holder may wear. Border control lives in the conditions:
>   aud  = the audience we mint tokens for
>   sub  = ONLY this project, pinned by IMMUTABLE PROJECT ID (84090295), not path.
> Why ID not path: GitLab refused to issue path-subject tokens because this project's path had a prior life (deleted project) — paths are recyclable and a recreated path would inherit path-pinned cloud trust. IDs can't be recycled. Requires the project setting id_token_sub_claim_components = ["project_id","ref_type","ref"] (set in GitLab, 2026-07-05).

```hcl
resource "aws_iam_role" "gitlab_ci" {
  name = "avertra-sockshop-gitlab-ci"
```

### why the CI role has admin for the assessment (D13 trade-off)
> Assessment trade-off (D13, documented before a reviewer asks): one role with admin for the week — CI runs the same authority the human runs. Production splits this into a read+plan role, a scoped apply role behind an approval environment, and an app-deploy role limited to ECR push + ECS update.

```hcl
resource "aws_iam_role_policy_attachment" "gitlab_ci_admin" {
  role       = aws_iam_role.gitlab_ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
```

## bootstrap/terraform.tfvars.example

### how to use this example file
> Copy to terraform.tfvars (gitignored) and fill in real values.

```hcl
budget_alert_emails = ["you@example.com"]
```

### optional overrides with their defaults
> Optional overrides (defaults shown):
> aws_region       = "us-east-1"
> budget_limit_usd = 25

```hcl
budget_alert_emails = ["you@example.com"]
```

## .gitignore

### section header: Terraform + what the .terraform dir holds
> ---- Terraform ----
> Local provider plugins, modules cache

```hcl
**/.terraform/*
.terraform.lock.hcl.backup
```

### why state files are ignored
> State files (remote state in S3; never commit local state)

```hcl
*.tfstate
*.tfstate.*
```

### why tfvars are ignored (secrets), example is the exception
> Variable files may contain secrets/account-specific values.
> Commit terraform.tfvars.example only.

```hcl
*.tfvars
*.tfvars.json
!*.tfvars.example
```

### plan artifacts
> Plan output artifacts

```hcl
*.tfplan
plan.out
```

### section header: secrets / credentials
> ---- Secrets / credentials ----

```hcl
.env
.env.*
```

### section header: OS / editor cruft
> ---- OS / editor cruft ----

```hcl
.DS_Store
Thumbs.db
```

---

## terraform/modules/network/main.tf

### module header — the L1 mental model
> Network module — implements the L1 mental model (see EXPLANATIONS.md):
> a sealed VPC, two failure domains, an inbound door (IGW), an outbound-only
> door (NAT, single — documented cost trade-off), and the free S3 bypass.

```hcl
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
```

### section banner — the sealed box
> ---------------------------------------------------------------- the sealed box

```hcl
resource "aws_vpc" "this" {
```

### why both DNS flags are on
> Both true so resources inside get/resolve DNS names — Service Connect
> discovery and the RDS endpoint hostname depend on VPC DNS working.

```hcl
  enable_dns_support   = true
  enable_dns_hostnames = true
```

### section banner — inbound door (public subnets)
> ------------------------------------------------- inbound door (public subnets)

```hcl
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
```

### why subnets are written explicitly, no loop
> ---------------------------------------------------------------------- subnets
> Written explicitly (no loop): at n=2 AZs, four named blocks are more readable
> and defensible than a clever loop. var.azs[0] = list indexing — first element.

```hcl
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[0]
```

### why map_public_ip_on_launch stays default false
> NOTE: map_public_ip_on_launch stays at its default (false) even here.
> Nothing in public subnets needs an automatic public IP: the ALB manages its
> own addresses and the NAT uses an EIP. Least surface, even where "public".

```hcl
  tags = { Name = "${var.name}-public-a" }
```

### why the NAT needs an Elastic IP (and what it costs)
> -------------------------------------------------- outbound-only door (the NAT)
> A NAT gateway needs a static public IP of its own — an Elastic IP.
> 💰 public IPv4 addresses bill ~$0.005/hr; the NAT itself ~$0.045/hr.

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"
```

### single NAT placement (trailing)
> single NAT in AZ-a — documented trade-off

```hcl
  subnet_id     = aws_subnet.public_a.id
```

### why the NAT needs depends_on
> First explicit depends_on in this repo: normally ordering comes from
> references (L2), but NAT never *references* the IGW — yet it cannot function
> until the VPC has one attached. depends_on states a dependency the reference
> graph can't see.

```hcl
  depends_on = [aws_internet_gateway.this]
```

### route tables — what actually makes a subnet public vs private
> ------------------------------------------------------------------ route tables
> THE defining fact of public vs private: it's not a checkbox on the subnet,
> it's which route table the subnet is associated with.

```hcl
resource "aws_route_table" "public" {
```

### the public route table
> Public = "unknown destinations exit via the Internet Gateway" (two-way door).

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
```

### the private route table — one shared table, multi-NAT upgrade path
> Private = "unknown destinations exit via the NAT" (outbound-only door).
> One shared table because there is one NAT; the multi-NAT production upgrade
> would split this into one table per AZ, each pointing at its local NAT.

```hcl
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
```

### the free S3 bypass — gateway endpoint rationale
> ------------------------------------------------------- the free S3 bypass (L1)
> Gateway endpoint = a route-table entry, not a device. Attached to the PRIVATE
> table: that's where the image-layer traffic originates. Free, so the heaviest
> traffic class (ECR layers from S3) never pays the NAT toll.

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
```

## terraform/modules/network/outputs.tf

### what the outputs file is for
> The module's return values — what later modules need to plug into this network.

```hcl
output "vpc_id" {
  description = "VPC id — security groups and the ALB need it."
```

## terraform/modules/ecs-cluster/main.tf

### module header — Fargate cluster is a logical boundary
> ECS cluster module — with Fargate this is a LOGICAL boundary, not machines:
> AWS runs the control plane (no fee), and there are no nodes — each task gets
> its own right-sized micro-VM at launch. Closer to "K8s namespace + scheduler
> defaults" than to a cluster.

```hcl
resource "aws_service_discovery_http_namespace" "this" {
```

### the namespace = the CoreDNS role; names are locked
> Service discovery registry (the CoreDNS role). Every service publishes its
> discovery name here; names MUST equal the hostnames baked into the sock-shop
> images (catalogue, carts, user-db, ...) — locked list in CLAUDE.md + D4.

```hcl
resource "aws_service_discovery_http_namespace" "this" {
  name        = var.name
  description = "Service Connect namespace for the sock-shop services"
```

### why Container Insights is enabled (and its cost)
> Container Insights = the cAdvisor/metrics-server role: per-service CPU,
> memory and task-count metrics into CloudWatch. Phase 4 dashboards and
> Phase 5 auto-scaling read these. 💰 bills as custom metrics (~$1-3/mo at
> our scale; gone when the stack is destroyed nightly).

```hcl
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
```

### service_connect_defaults — automatic namespace membership
> Every service created in this cluster joins the namespace automatically.

```hcl
  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }
```

## terraform/modules/alb/main.tf

### module header — ALB parts mapped to K8s roles
> ALB module — the inbound door (L1): internet → ALB → front-end, nothing else.
> Three parts map to K8s roles: aws_lb = the Ingress controller appliance,
> aws_lb_target_group = EndpointSlice + readinessProbe, aws_lb_listener = the rule.

```hcl
resource "aws_security_group" "alb" {
```

### first link of the least-privilege SG chain
> First link of the least-privilege SG chain (CLAUDE.md):
>   internet --80--> alb-sg --8079--> frontend-sg --> backend-sg --> data/rds-sg
> SGs are STATEFUL (replies auto-allowed; rules describe who may INITIATE) and can
> name other SGs as source — identity-based, like a NetworkPolicy podSelector.

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB: HTTP from the internet"
```

### the one legitimate 0.0.0.0/0 ingress
> The ONE place "from anywhere" is correct: this is the public front door.

```hcl
  ingress {
    description = "HTTP from the internet"
    from_port   = 80
```

### why egress stays open — chain enforced on ingress
> Chain is enforced on ingress (the initiating direction); egress stays open —
> standard pattern, keeps rules readable as "who may start a conversation".

```hcl
  egress {
    description = "All outbound"
    from_port   = 0
```

### internal = false (trailing)
> public-facing — the only public entry to the app

```hcl
  internal           = false
```

### subnets span two AZs (trailing)
> >= 2 AZs required by ALBs

```hcl
  subnets            = var.public_subnet_ids
```

### drop_invalid_header_fields — a real tfsec fix, not an ignore
> Real fix from the tfsec sweep (not an ignore): malformed-header requests
> are dropped at the door instead of reaching Node.

```hcl
  drop_invalid_header_fields = true
```

### why target_type is "ip" on Fargate
> Fargate/awsvpc gives every task its own ENI + private IP (pod-IPs, literally),
> so the ALB targets IPs. "instance" is the NodePort-era pattern — no instances here.

```hcl
  target_type = "ip"
```

### deregistration_delay = 30 (connection draining)
> Connection draining: stop NEW traffic instantly on removal, give in-flight
> requests 30s to finish (default 300s = pointlessly slow rollouts for a demo).

```hcl
  deregistration_delay = 30
```

### the health check = readinessProbe, ALB edition
> The readinessProbe, ALB edition: fail 3x -> pulled from rotation.

```hcl
  health_check {
    path                = var.health_check_path
    interval            = 30
```

### the listener = the Ingress rule; HTTPS is a documented upgrade
> The Ingress rule: on :80, forward everything to the front-end group.
> (HTTPS/ACM is a documented production upgrade, not built in the time box.)

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
```

---

## terraform/modules/ecs-service/main.tf

### module header — the reusable heart, K8s mapping
> ecs-service module — the reusable heart, instantiated once per service (13x).
> Mapping for K8s eyes: task definition = pod spec, service = Deployment,
> Service Connect block = Service registration in DNS.

```hcl
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.project}/${var.name}"
  retention_in_days = var.log_retention_days
```

### logging section divider
> ------------------------------------------------------------------ logging

```hcl
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.project}/${var.name}"
  retention_in_days = var.log_retention_days
```

### execution role vs task role — the two identities (execution role)
> ------------------------------------------------------- the two identities
> EXECUTION role: used by the ECS PLATFORM before/around the container —
> pull image, write logs, (Phase 2) fetch secrets to inject.
> K8s analog: the kubelet's credentials. Pull/log failures point HERE.

```hcl
resource "aws_iam_role" "execution" {
  name = "${var.project}-${var.name}-execution"
```

### conditional secrets-read policy on the execution role
> Phase-2 extension: services that inject secrets need their EXECUTION role
> (injection is a platform job — L14/D10) allowed to read EXACTLY those
> parameters, nothing wider. count 0/1 = the conditional-resource pattern:
> services without secrets don't even get the policy object.

```hcl
resource "aws_iam_role_policy" "secrets_access" {
  count = length(var.secrets) > 0 ? 1 : 0
```

### task role — deliberately empty (least privilege)
> TASK role: assumed by the APPLICATION CODE for AWS API calls at runtime.
> K8s analog: the pod's ServiceAccount. Deliberately EMPTY — our apps make no
> AWS calls, so their runtime identity has no permissions (least privilege).
> Runtime AccessDenied in app logs would point HERE.

```hcl
resource "aws_iam_role" "task" {
  name = "${var.project}-${var.name}-task"
```

### pod spec section divider
> ------------------------------------------------------------ the pod spec

```hcl
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.project}-${var.name}"
```

### awsvpc network mode = pod-IPs (inline)
> each task gets its own ENI + private IP (pod-IPs)

```hcl
  network_mode             = "awsvpc"
```

### container_definitions: jsonencode + merge() for optional entryPoint/command
> container_definitions is historically a JSON-string field: jsonencode turns
> clean HCL into that JSON. The for-expressions reshape our friendly maps into
> the list-of-objects the ECS API demands. merge() + the null-to-{} ternary
> includes entryPoint/command in the JSON ONLY when a caller sets them
> (catalogue's sh-wrapper); everyone else keeps the image defaults untouched.

```hcl
  container_definitions = jsonencode([
    merge(
      {
```

### port name — Service Connect target (inline)
> port name — Service Connect points at this

```hcl
          name          = var.name
```

### Deployment section divider
> ---------------------------------------------------------- the Deployment

```hcl
resource "aws_ecs_service" "this" {
  name            = var.name
```

### health-check grace only for ALB-attached services
> ALB-attached services get 60s of grace before health checks can kill slow
> starters (front-end is a slow Node boot); everyone else needs none.

```hcl
  health_check_grace_period_seconds = var.target_group_arn == null ? null : 60
```

### no public IPs on tasks (inline)
> locked: tasks are unroutable from outside; pulls go via NAT

```hcl
    assign_public_ip = false
```

### Service Connect registration — server AND client
> Registers var.name in the sockshop namespace — front-end reaching
> http://catalogue/ resolves through this. Enabling it also makes this task a
> Service Connect CLIENT (needed to resolve others).

```hcl
  service_connect_configuration {
    enabled   = true
    namespace = var.namespace_arn
```

### port_name must match portMapping (inline)
> must match the portMapping name above

```hcl
      port_name      = var.name
```

### dns_name must be explicit — bare hostnames (D12 debugging story)
> dns_name MUST be explicit: AWS defaults an omitted dnsName to
> "discoveryName.namespace" (catalogue.sockshop) — but the images dial
> BARE hostnames (catalogue). Cost of the default: ENOTFOUND everywhere.
> (Debugging story of 2026-07-04, D12.)

```hcl
        dns_name = var.name
        port     = var.container_port
```

### the port callers dial (inline)
> the port callers dial

```hcl
        port     = var.container_port
```

### circuit breaker = the rollback story
> The rollback story: if new tasks keep failing to start or go unhealthy
> during a deploy, ECS halts the rollout and reverts to the last working
> revision automatically. (Production upgrade path: CodeDeploy blue/green.)

```hcl
  deployment_circuit_breaker {
    enable   = true
    rollback = true
```

### ignore_changes on desired_count — autoscaler owns replicas
> Phase 5: the autoscaler owns the replica count at RUNTIME. Without this,
> every terraform apply would fight the autoscaler back down to desired_count
> (the K8s classic: HPA vs a hardcoded replicas field in the manifest).
> Trade-off: desired_count is now creation-time-only from Terraform's side.

```hcl
  lifecycle {
    ignore_changes = [desired_count]
  }
```

### dynamic load_balancer block — only front-end renders it
> dynamic = render this nested block 0..N times; here 0 or 1: only front-end
> passes a target group; the other 12 instantiations render no block at all.

```hcl
  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]
```

## terraform/modules/rds/main.tf

### module header — D10 end-to-end secret chain
> RDS module — catalogue-db replaced by managed MySQL (locked decision).
> Implements D10 end-to-end: generated password -> SSM SecureString -> injected
> at task launch. Plaintext never in code, task defs, or git (state caveat: D10).

```hcl
resource "random_password" "master" {
  length  = 32
  special = false
```

### random_password: special=false satisfies two charsets
> random_password is a RESOURCE from the hashicorp/random provider: "creating" it
> generates the value once and remembers it in state (D10 caveat lives here).
> special = false (alphanumeric only) ON PURPOSE, satisfying two charsets at once:
>   - RDS forbids / @ " and spaces in master passwords
>   - the Go MySQL DSN (user:pass@tcp(...)) would mis-parse : / @ in a password

```hcl
resource "random_password" "master" {
  length  = 32
  special = false
```

### D10: password at rest in SSM SecureString
> D10: the password at rest — encrypted with KMS, free standard tier.

```hcl
resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project}/rds/master-password"
  type  = "SecureString"
```

### subnet group = placement contract
> Which subnets RDS may place instances in (and where a multi-AZ standby lands:
> the OTHER private subnet). Placement contract, like a nodeSelector over subnets.

```hcl
resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-rds"
  subnet_ids = var.subnet_ids
```

### MySQL 8 auth-plugin compatibility (defense story)
> Compatibility note (defense story): MySQL 8's default auth plugin is
> caching_sha2_password; catalogue:0.3.5 embeds a ~2017 Go MySQL driver that
> predates it and would fail the handshake. First attempt: force
> default_authentication_plugin=mysql_native_password via a parameter group —
> REJECTED by AWS at apply time ("cannot be modified" on current 8.0 engines).
> Actual fix: the SEED task (modern mysql:8 client, unaffected) runs
> ALTER USER ... IDENTIFIED WITH mysql_native_password before catalogue ever
> connects. Compatibility handled at the USER level, not the server level.

```hcl
resource "aws_db_instance" "this" {
  identifier     = "${var.project}-catalogue-db"
  engine         = "mysql"
```

### storage encryption free (inline)
> free, standard posture

```hcl
  storage_encrypted = true
```

### multi_az flip for demo day (inline)
> false in dev; true for demo day (locked)

```hcl
  multi_az            = var.multi_az
```

### never publicly accessible (inline)
> locked: reachable only via rds-sg inside the VPC

```hcl
  publicly_accessible = false
```

### destroyability decisions header
> Destroyability decisions (nightly destroy is a feature, not neglect):

```hcl
  skip_final_snapshot     = true
  backup_retention_period = 0
```

### skip_final_snapshot (inline)
> else destroy blocks demanding a snapshot name

```hcl
  skip_final_snapshot     = true
```

### backup retention 0 in dev (inline)
> no automated backups in dev (prod: >= 7 days — docs)

```hcl
  backup_retention_period = 0
```

### catalogue DSN assembled as one SecureString, delivered via sh -c
> D10, catalogue's half: the COMPLETE DSN as one SecureString, assembled here where
> all parts are known. endpoint already includes ":3306" (host:port attribute).
> Delivery (review-workflow catch): catalogue reads -DSN as a FLAG only and ECS does
> no $(VAR) substitution in command — so SSM injects this as env var DSN, and the
> container launches via sh -c 'exec /app -port=80 -DSN="$DSN"' (wired in the
> catalogue unit; needs the ecs-service entrypoint/command extension).

```hcl
resource "aws_ssm_parameter" "catalogue_dsn" {
  name  = "/${var.project}/catalogue/dsn"
  type  = "SecureString"
```

## terraform/modules/rds/versions.tf

### second provider: hashicorp/random
> This module needs a SECOND provider: hashicorp/random. Modules declare their
> own requirements; init aggregates them across the whole root and downloads both.

```hcl
terraform {
  required_version = ">= 1.10"
```

## terraform/modules/monitoring/main.tf

### module header — infra vs APP health framing
> Monitoring module — Phase 4. The framing (docs sentence, Ahmad's APM line):
> infra monitoring answers "is the box healthy"; the dashboard's p99 + 5xx
> answer "is the APP healthy". Alarms notify the humans via SNS email.

```hcl
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}
```

### alerting section divider
> ------------------------------------------------------------------ alerting

```hcl
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}
```

### email subscriptions start PENDING
> Email subscriptions start PENDING until the recipient clicks the link AWS
> sends — an unconfirmed subscription silently receives nothing.

```hcl
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
```

### dashboard: one JSON doc, for-expressions fan out services
> ------------------------------------------------------------------ dashboard
> One JSON document; for-expressions fan the 13 services into per-line metrics.

```hcl
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-overview"
```

### alarms: 5 tripwires, one topic
> ------------------------------------------------------------------- alarms
> 5 tripwires; every one notifies (and resolves) via the same topic.

```hcl
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx"
```

### notBreaching: no traffic is not an incident (inline)
> no traffic = no news, not an incident

```hcl
  treat_missing_data  = "notBreaching"
```

### percentile stats use extended_statistic (inline)
> percentile stats use extended_statistic, not statistic

```hcl
  extended_statistic  = "p99"
```

### storage threshold unit (inline)
> bytes

```hcl
  threshold           = 2000000000
```

### missing storage data IS alarming (inline)
> missing storage data IS alarming

```hcl
  treat_missing_data  = "breaching"
```

---

# Comments migrated — batch D

## terraform/envs/dev/versions.tf

### Provider pinning discipline
> Same pinning discipline as bootstrap — both roots must agree on provider majors.

```
terraform {
  required_version = ">= 1.10"
```

## terraform/envs/dev/backend.tf

### Remote state location + why values are hard-coded
> Remote state: this root's state lives in the bootstrap-created S3 bucket.
>
> Values are hard-coded ON PURPOSE: backend config is evaluated at `terraform init`,
> before variables exist — Terraform cannot interpolate anything here. This is a
> well-known TF constraint, not sloppiness.

```
terraform {
  backend "s3" {
```

### Path-style state key
> path-style key leaves room for envs/prod later

```
    key    = "envs/dev/terraform.tfstate"
```

### Native S3 state locking
> Native S3 state locking (TF >= 1.10): a lock object placed next to the state
> file stops two concurrent applies corrupting it — no DynamoDB table needed
> (older setups you'll see online use one; that pattern is obsolete since 1.10).

```
    use_lockfile = true
```

## terraform/envs/dev/network.tf

### Network module instantiation (Helm analogy)
> Instantiate the network module (Helm analogy: `helm install network ./modules/network`).
> Only aws_region is passed; every other input uses the module's defaults —
> they're visible in terraform/modules/network/variables.tf.

```
module "network" {
  source = "../../modules/network"
```

## terraform/envs/dev/cluster.tf

### ECS cluster + namespace
> The ECS cluster + Service Connect namespace (module defaults name both "sockshop").

```
module "ecs_cluster" {
  source = "../../modules/ecs-cluster"
```

## terraform/envs/dev/alb.tf

### Public entry point / composition layer
> The public entry point. First cross-module wiring: network's outputs feed
> the ALB's inputs — the root is the composition layer.

```
module "alb" {
  source = "../../modules/alb"
```

### front-end container port pin
> front-end's container port — pinned by SERVICES.md (verified from the K8s
> manifest: containerPort 8079, probes on 8079).

```
  target_port = 8079
```

### Root-level URL output
> Surface the URL at the root level so `terraform output alb_dns_name` just works.

```
output "alb_dns_name" {
  description = "Public URL of the storefront."
```

## terraform/envs/dev/security-groups.tf

### Tier SGs — least-privilege chain + chain link #2
> Tier security groups — the least-privilege chain (CLAUDE.md). They live at the
> root (not in a module) because they are exactly the wiring BETWEEN modules.
> Chain link #2: only the ALB may talk to front-end, and only on its port.

```
resource "aws_security_group" "frontend" {
  name        = "sockshop-frontend-sg"
```

### SG-as-source
> SG-as-source: the NetworkPolicy podSelector move

```
    security_groups = [module.alb.alb_sg_id]
```

### Chain link #3 — backend self-reference
> Chain link #3: backends accept 80 from front-end AND from each other.
> self = true covers every backend->backend pair (orders -> carts/user/payment/
> shipping) in one line — membership-based, like a NetworkPolicy selecting its own pods.

```
resource "aws_security_group" "backend" {
  name        = "sockshop-backend-sg"
```

### Chain link #4 — data tier
> Chain link #4: the data tier accepts only its exact protocols from its exact clients.

```
resource "aws_security_group" "data" {
  name        = "sockshop-data-sg"
```

### Chain link #5 — RDS
> Chain link #5: RDS accepts MySQL from backends only (catalogue is its one real client).

```
resource "aws_security_group" "rds" {
  name        = "sockshop-rds-sg"
```

## terraform/envs/dev/frontend.tf

### The walking skeleton's service
> front-end — the walking skeleton's one service. First instantiation of the
> reusable ecs-service module (12 more follow in Phase 2).

```
module "front_end" {
  source = "../../modules/ecs-service"
```

### Service Connect ordering (D12)
> Service Connect ordering (D12): a client's endpoint list is a SNAPSHOT taken
> at DEPLOYMENT creation — servers registered later are invisible until the
> client redeploys. On fresh builds, front-end must therefore be created LAST,
> after every service it calls. (AWS documents the same rule for CFN dependsOn.)

```
  depends_on = [
    module.catalogue,
```

### Phase-3 image flip (front-end)
> Phase-3 flip (D8/D13): served from OUR registry; the pipeline's mirror job is
> the only road in (upstream was weaveworksdemos/front-end:0.3.12).

```
  image          = "${local.ecr}/front-end:stable"
```

### Port source
> SERVICES.md

```
  container_port = 8079
```

### HA baseline
> two tasks across two AZs — the HA baseline

```
  desired_count = 2
```

### Shared sessions (D4)
> D4: sessions live in session-db so both tasks share them

```
    SESSION_REDIS = "true"
```

### The one ALB attachment
> The one ALB attachment in the whole system.

```
  target_group_arn = module.alb.target_group_arn
```

## terraform/envs/dev/backends.tf

### Backend tier sizing rules
> Backend tier — 7 services. Java services (carts/orders/shipping/queue-master)
> get 0.5 vCPU / 1024 MB + JAVA_OPTS (from compose; without it: slow boot + Zipkin
> noise). Go services (catalogue/payment/user) run on the 0.25/512 default.
> All wear backend-sg; Service Connect names match SERVICES.md exactly.

```
locals {
  java_opts = "-Xms64m -Xmx128m -XX:+UseG1GC -Djava.security.egd=file:/dev/urandom -Dspring.zipkin.enabled=false"
}
```

### catalogue — secret + launch wrapper
> catalogue — the one service with a secret AND a launch wrapper (review catch #2):
> its binary reads the DSN only as a -DSN flag and ECS does no $(VAR) substitution
> in command, so: SSM injects env DSN (D10) -> sh -c turns it into the flag at
> launch. Plaintext DSN never appears in the task definition or console.

```
module "catalogue" {
  source = "../../modules/ecs-service"
```

### Phase-3 image flip (catalogue)
> Phase-3 flip (was weaveworksdemos/catalogue:0.3.5)

```
  image          = "${local.ecr}/catalogue:stable"
```

### DSN expansion location
> $DSN expands IN the container

```
  container_command    = ["exec /app -port=80 -DSN=\"$DSN\""]
```

### user depends_on
> D12 ordering

```
  depends_on = [module.user_db]
```

### Phase-3 image flip (user)
> Phase-3 flip (was weaveworksdemos/user:0.4.4, D6)

```
  image          = "${local.ecr}/user:stable"
```

### MONGO_HOST source
> D6: explicit env name from compose

```
    MONGO_HOST = "user-db:27017"
```

### Phase-3 image flip (payment)
> Phase-3 flip (was weaveworksdemos/payment:0.4.3)

```
  image          = "${local.ecr}/payment:stable"
```

### carts depends_on
> D12 ordering

```
  depends_on = [module.carts_db]
```

### Phase-3 image flip (carts)
> Phase-3 flip (was weaveworksdemos/carts:0.4.8)

```
  image          = "${local.ecr}/carts:stable"
```

### Java sizing floor
> Java floor (CLAUDE.md sizing)

```
  cpu    = 512
```

### orders depends_on
> D12 ordering: orders calls carts/user/payment/shipping — create them first.

```
  depends_on = [
    module.carts,
```

### Phase-3 image flip (orders)
> Phase-3 flip (was weaveworksdemos/orders:0.4.7)

```
  image          = "${local.ecr}/orders:stable"
```

### shipping depends_on
> D12 ordering

```
  depends_on = [module.rabbitmq]
```

### Phase-3 image flip (shipping)
> Phase-3 flip (was weaveworksdemos/shipping:0.4.8)

```
  image          = "${local.ecr}/shipping:stable"
```

### queue-master docker.sock trade-off
> queue-master: compose mounts docker.sock — NOT replicated on Fargate (impossible
> and unneeded for the demo; documented trade-off in SERVICES.md).

```
module "queue_master" {
  source = "../../modules/ecs-service"
```

### queue-master depends_on
> D12 ordering

```
  depends_on = [module.rabbitmq]
```

### Phase-3 image flip (queue-master)
> Phase-3 flip (was weaveworksdemos/queue-master:0.3.1)

```
  image          = "${local.ecr}/queue-master:stable"
```

## terraform/envs/dev/data-tier.tf

### Data tier — ephemeral by design
> Data tier — 5 services, all ephemeral by design (documented trade-off:
> prod = DocumentDB/Atlas for the mongos, Amazon MQ for rabbit, ElastiCache for
> redis). user-db re-seeds itself on every start; carts/orders data is demo-
> disposable. Service Connect names MUST match SERVICES.md exactly.

```
module "rabbitmq" {
  source = "../../modules/ecs-service"
```

### Phase-3 image flip (rabbitmq)
> Phase-3 flip (was rabbitmq:3.6.8; plain, not -management — SERVICES.md)

```
  image          = "${local.ecr}/rabbitmq:stable"
```

### Phase-3 image flip (carts-db)
> Phase-3 flip (was mongo:3.4, D5)

```
  image          = "${local.ecr}/carts-db:stable"
```

### Phase-3 image flip (orders-db)
> Phase-3 flip (was mongo:3.4, D5)

```
  image          = "${local.ecr}/orders-db:stable"
```

### Phase-3 image flip (user-db)
> Phase-3 flip (was weaveworksdemos/user-db:0.4.0; seed users baked in)

```
  image          = "${local.ecr}/user-db:stable"
```

### Phase-3 image flip (session-db)
> Phase-3 flip (was redis:alpine, D4 — now pinned by OUR mirror, not a moving upstream tag)

```
  image          = "${local.ecr}/session-db:stable"
```

## terraform/envs/dev/rds.tf

### catalogue-db as managed MySQL
> catalogue-db as managed MySQL (locked decision; module: terraform/modules/rds).
> multi_az stays false until demo day (module default; flip via argument then).

```
module "rds" {
  source = "../../modules/rds"
```

## terraform/envs/dev/seed.tf

### One-off RDS seeding task — full design note
> One-off RDS seeding task — the K8s Job analog: a task definition with no
> service around it, executed on demand via `aws ecs run-task` (kubectl run
> --restart=Never). Runs a MODERN mysql:8 client, which does three things:
>   1. ALTER USER -> mysql_native_password  (the catalogue-driver compat fix;
>      the server-level parameter is immutable on current RDS MySQL 8.0)
>   2. import seed/dump.sql (versioned in-repo; GRANT line stripped — MySQL 8
>      no longer auto-creates users on GRANT and the master already owns socksdb)
>   3. SELECT COUNT(*) FROM sock  -> the verification, visible in the task's logs
>
> Secret hygiene: the password reaches the container ONLY as env MYSQL_PWD via
> SSM injection (D10). The ALTER statement interpolates $MYSQL_PWD INSIDE the
> container at runtime — never in the task definition, console, or logs.

```
locals {
  seed_dump = file("${path.module}/seed/dump.sql")
```

### Bare $VAR passthrough
> Bare $VAR (no braces) on purpose: Terraform only interpolates on ${...},
> so these pass through to the shell untouched.

```
  seed_script = <<-EOT
    set -e
```

### Execution-role SSM scope
> The execution role fetches the password to inject it (D10: injection is an
> EXECUTION-role job). Scoped to exactly one parameter.

```
resource "aws_iam_role_policy" "seed_ssm" {
  name = "read-rds-password"
```

### mysql:8.0 entrypoint behavior
> official image's entrypoint execs any non-mysqld command

```
      image     = "mysql:8.0"
```

## terraform/envs/dev/loadtest.tf

### user-sim — on-demand task, Docker Hub on purpose
> user-sim load generator — NOT a service (SERVICES.md): an on-demand task,
> run via `aws ecs run-task` for the scale-out demo, exactly like the seed
> task is a K8s Job. Image stays Docker Hub direct on purpose: it's a test
> TOOL, not part of the application supply chain (documented trade-off).

```
#tfsec:ignore:aws-cloudwatch-log-group-customer-key -- accepted 2026-07-07: same rationale as service log groups
resource "aws_cloudwatch_log_group" "loadtest" {
```

### Execution role reuse
> Reuses the seed task's execution role: identical needs (pull + logs, no secrets).

```
  execution_role_arn = aws_iam_role.seed_execution.arn
```

### Load-test flags verified from logs
> Flags verified from the task's own logs (2026-07-07): -r is TOTAL
> REQUESTS (not a rate!), -c concurrent clients. 10 clients ~ 30 req/s,
> so 10000 requests ~ 5-6 sustained minutes — what target tracking needs
> (3+ min above target). ALB DNS resolved by Terraform: always aimed at
> the CURRENT load balancer, every rebuild.

```
      command = ["-r", "10000", "-c", "10", "-h", module.alb.alb_dns_name]
```

## terraform/envs/dev/autoscaling.tf

### Phase 5 — target tracking explained
> Phase 5 — auto-scaling on front-end (HPA, ECS edition).
> Target tracking = "keep this metric AT this value": AWS creates and manages
> the underlying CloudWatch alarms itself (visible in the console, named
> TargetTracking-*) and scales to hold the target. Two policies, either can
> trigger a scale-out; scale-IN only when BOTH agree capacity is excessive.

```
resource "aws_appautoscaling_target" "front_end" {
  service_namespace  = "ecs"
```

### Scalable dimension registration
> Registers front-end's desired count as a scalable dimension (min/max bounds).

```
resource "aws_appautoscaling_target" "front_end" {
  service_namespace  = "ecs"
```

### min_capacity rationale
> never below the HA baseline

```
  min_capacity       = 2
```

### max_capacity rationale
> demo ceiling (cost guardrail)

```
  max_capacity       = 5
```

### depends_on for opaque resource_id
> resource_id is just a string — Terraform can't see the service inside it,
> so the ordering must be stated (same class of fix as D12).

```
  depends_on = [module.front_end]
```

### Policy 1 — CPU target
> Policy 1: average CPU across front-end tasks at 60%.

```
resource "aws_appautoscaling_policy" "front_end_cpu" {
  name               = "front-end-cpu-60"
```

### Scale-out cooldown
> add capacity fast

```
    scale_out_cooldown = 60
```

### Scale-in cooldown
> remove it cautiously (flap damping)

```
    scale_in_cooldown  = 120
```

### Policy 2 — requests per target
> Policy 2: requests per target at 100/min — the traffic-shaped signal that
> reacts before CPU does (the load test is designed to trip this one).

```
resource "aws_appautoscaling_policy" "front_end_requests" {
  name               = "front-end-req-per-target-100"
```

### resource_label meaning
> "which target group's request count": <alb-suffix>/<tg-suffix>

```
      resource_label = "${module.alb.alb_arn_suffix}/${module.alb.tg_arn_suffix}"
```

## terraform/envs/dev/monitoring.tf

### Phase 4 — variable p99 threshold for the alarm test
> Phase 4 — dashboards + alarms. The p99 threshold is a variable so the
> acceptance test can fire a REAL alarm (drop to 0.05, generate traffic,
> receive email, restore 2).

```
module "monitoring" {
  source = "../../modules/monitoring"
```

### Alert email address
> same address as the budget alerts

```
  alert_email    = "ahmad.ibhaiss@outlook.com"
```

## terraform/envs/dev/locals.tf

### Our registry — the only road in
> Our registry — after the Phase-3 flip, every service deploys from HERE, never
> from Docker Hub: images enter only via the pipeline (pull -> scan -> push),
> and ECS pulls layers over the free S3 gateway endpoint instead of the NAT toll.

```
locals {
  ecr = "448049810701.dkr.ecr.us-east-1.amazonaws.com/sockshop"
}
```

## .gitlab-ci.yml

### Pipeline header — two flows, OIDC only
> Avertra Sock Shop — two flows in one pipeline (D13):
>   INFRA: fmt/validate/tfsec -> plan (artifact) -> MANUAL apply   (Continuous Delivery, not Deployment)
>   APP:   mirror upstream -> Trivy scan -> push :sha + :stable to ECR -> manual per-service deploy
> Auth: OIDC only — zero stored AWS credentials (bootstrap/oidc.tf, D13).

```
variables:
  AWS_DEFAULT_REGION: us-east-1
```

### The OIDC handshake
> The whole OIDC handshake: GitLab mints a signed job identity (the passport);
> these two env vars make every AWS SDK (terraform, aws cli) trade it at STS
> for ~1h credentials automatically. Nothing stored, nothing to rotate.

```
.aws-auth:
  id_tokens:
```

### INFRA FLOW section marker
> ---------------------------------------------------------------- INFRA FLOW

```
tf-fmt:
  stage: validate
```

### Backend-less init
> no AWS needed for a schema check

```
    - terraform init -backend=false -input=false
```

### tfsec — blocking gate policy (D15) [removed outside this pass; recorded so the prose is preserved]
> Phase-5 hardened (D15): BLOCKING, both roots, zero unexplained findings —
> every accepted risk is an inline #tfsec:ignore with a dated justification.

```
tfsec:
  stage: validate
```

### drift-check — scheduled reconciliation
> Phase-5 stretch (D15): drift detection. Terraform reconciles only when RUN
> (L4: "a reconciliation you schedule, not a controller loop") — this job IS the
> schedule. plan -detailed-exitcode: 0 = reality matches the diary, 2 = DRIFT
> (job fails -> notification), 1 = error. Runs on a pipeline schedule (create
> under Build -> Pipeline schedules, e.g. nightly) or manually for demos.
> Remediation is ALWAYS review + gated apply — never auto-revert.

```
drift-check:
  stage: validate
```

### Backend init via OIDC
> S3 backend auths via the OIDC env vars

```
    - terraform init -input=false
```

### tf-apply — THE manual gate
> THE manual gate — Continuous Delivery, not Deployment: the pipeline makes the
> release possible; a human makes it happen. Applies exactly the reviewed artifact.

```
tf-apply:
  stage: apply
```

### resource_group on apply
> serialize applies — one writer, like the state lock story

```
  resource_group: dev
```

### APP FLOW section marker + supply-chain story
> ------------------------------------------------------------------ APP FLOW
> Supply-chain story: upstream images are pulled ONCE, scanned, then served
> from OUR registry under both an immutable :sha tag (audit) and :stable (D8).

```
.service-matrix:
  parallel:
```

### Trivy install step
> Trivy binary (scan the upstream BEFORE it enters our registry)

```
    - curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
```

### Legacy-image scan policy (D15)
> Phase-5 policy (D15): legacy pinned images scan as a RISK MANIFEST
> (report-only — their CVE sets are the documented accepted register in
> .trivyignore); the scan-gate job below proves CRITICAL-blocking for
> anything new.

```
    - trivy image --severity HIGH,CRITICAL --exit-code 0 "$UPSTREAM"
```

### ECR auth without aws-cli
> ECR auth WITHOUT aws-cli: Amazon's Go credential helper, from Alpine's own
> package repo (the apk aws-cli broke on musl/pyexpat; Amazon's S3 download
> paths are dead; GitHub releases ship no binaries — Alpine packages it).
> Docker invokes the helper automatically; it consumes the same OIDC env
> vars; no registry password ever touches stdout or the job log.

```
    - apk add --no-cache docker-credential-ecr-login
    - mkdir -p ~/.docker
```

### scan-gate-demo — expected red job
> D15 acceptance evidence: the blocking gate, demonstrated. Scans a known-dirty
> image with --exit-code 1 and NO ignore file — this job is EXPECTED TO FAIL
> (allow_failure so the pipeline survives): a red job here is the screenshot
> that proves a CRITICAL vuln blocks promotion for non-legacy images.

```
scan-gate-demo:
  stage: mirror
```

### tf-destroy — double-locked cost ritual (D14)
> The nightly cost ritual as a pipeline button (D14). Destroys the DEV root only —
> bootstrap (state bucket, ECR, budget, OIDC) is never pipeline-destroyed.
> TWO locks: the manual trigger AND a typed confirmation — when pressing play,
> add variable CONFIRM_DESTROY = sockshop-dev, or the job refuses.

```
tf-destroy:
  stage: destroy
```

### resource_group on destroy
> never concurrent with an apply

```
  resource_group: dev
```
