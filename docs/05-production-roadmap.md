# 05 — Production Roadmap

What changes if this system carried real traffic and real data. Big-ticket items only — each maps back to a decision recorded in [04-tradeoffs.md](04-tradeoffs.md).

1. **HTTPS everywhere, plus a WAF.** An ACM certificate on the ALB, a 443 listener with HTTP→HTTPS redirect, and AWS WAF in front of the only public entry point.

2. **A NAT gateway per availability zone.** Today a single NAT is a cost decision; in production, an AZ loss must not degrade egress for the surviving zone.

3. **A managed data tier.** Replace the Mongo, Redis, and RabbitMQ containers with DocumentDB, ElastiCache, and Amazon MQ — with authentication enabled and credentials in the same secrets flow as the database.

4. **Protect the stateful layer.** RDS stays Multi-AZ with automated backups and point-in-time recovery; database resources move into their own Terraform root with deletion protection and a mandatory final snapshot, so day-to-day applies structurally cannot touch data.

5. **Modern application images.** Rebuild the 2016–2018 services on current base images — this retires the frozen-CVE risk manifest and lets image scanning block on findings normally, with continuous re-scanning (Amazon Inspector) catching new CVEs in already-stored images.

6. **Releases visible to Terraform.** Deploy by immutable image tags (commit SHA) threaded through Terraform, so every release is a reviewable plan diff and rollback is a git revert — retiring the mutable `:stable` pointer and its separate deploy step.

7. **Distributed tracing.** Add the third observability pillar (X-Ray / OpenTelemetry) once the applications are rebuilt on instrumentable bases; today's stack is metrics and logs.

8. **A Kubernetes path, if the platform standard requires it.** The design maps one-to-one onto EKS — task definitions to pod specs, tasks to pods, services to Deployments, Service Connect to Service DNS, target tracking to HPA — so the migration is a translation, not a redesign.

Finer-grained hardening (per-service security groups, OIDC trust pinned to the protected branch, scoped CI roles).
