# Defense Question Bank — the self-quiz workbook

**How to use this file:** after the project is finished, come back here cold. For each
question: answer OUT LOUD, in full sentences, as if the DevOps lead just asked it.
Only then open the referenced lesson (EXPLANATIONS.md L#) or decision (DECISIONS.md D#)
and grade yourself. A question you can't answer aloud isn't known yet — it's recognized.

Questions accumulate here at every session close (same numbering as EXPLANATIONS.md's
bank). Sunday count: 28.

---

## A. Terraform & the diary (state, plans, the tool itself)

1. Why does bootstrap keep local state while the main root uses S3 — and what breaks if
   you flip that? *(L4)*
2. `for_each` vs `count` for the 13 ECR repos — what happens under each when a service is
   removed from the middle of the list? *(ecr.tf / L2)*
6. Why is `terraform.tfvars` gitignored but `.terraform.lock.hcl` committed? *(L5/L10)*
7. What exactly does a saved plan file freeze, and why does that make the approval gate
   trustworthy? *(L9)*
8. Why does the NAT gateway carry an explicit `depends_on` when every other resource
   orders itself automatically? *(L11)*
26. Why can a destroy job added to the pipeline TODAY tear down infrastructure created
    days before the job existed? *(L19 — stateless executors; the diary owns everything)*

## B. The sealed box (networking & security groups)

3. The single NAT's AZ dies. What keeps working, what degrades, and why is that
   acceptable here? *(L1)*
5. Which rows of the L1 traffic map change if we adopt interface endpoints? *(L1)*
9. What makes a subnet "public"? Point at the exact resource and line that decides
   it. *(L11)*
10. Why is `map_public_ip_on_launch` left false even on the public subnets? *(L11)*
14. Your SG rules mostly name other SGs instead of CIDRs — why is that better here, and
    what's the K8s equivalent? *(L13)*

## C. ECS, the mesh & the data tier

11. "So how many nodes are in your ECS cluster?" — the trap question. Answer it. *(L12)*
12. Why must Service Connect discovery names exactly match the compose hostnames —
    where is the constraint actually coming from? *(L12)*
13. Why is the ALB's target group `target_type = "ip"` and not `"instance"`? *(L13)*
15. What does `deregistration_delay = 30` buy you during a deploy? *(L13)*
16. Your task pulls its image fine but the app gets AccessDenied calling S3 — which of
    the two roles is wrong, and why are you sure? *(L14)*
17. Walk me through what the deployment circuit breaker does when a bad image
    ships. *(L14)*
18. Why is the task role deliberately empty, and where will the secret-reading
    permission land instead? *(L14/D10)*
19. All 13 services are green, Cloud Map shows every instance, sidecars run — and a
    client still gets ENOTFOUND. Walk the three-layer diagnosis. *(L17 case 9 — the star)*
20. Why did killing and replacing a front-end task NOT fix its stale service list, when
    a `--force-new-deployment` did? *(L17 — fresh task ≠ fresh deployment)*
21. Your seed task runs ALTER USER before the import — why, and why THERE instead of a
    server parameter? *(L17 case 6 / D-notes in rds module)*
22. What single command sequence tells you whether a Service Connect resolution failure
    is a snapshot-staleness problem? *(L16 ladder — compare client deployment createdAt
    vs server registration)*

## D. Pipeline, passports & supply chain

23. Your pipeline stores zero AWS credentials — walk one job's authentication from
    `id_tokens` to STS to the S3 backend. *(L19/D13)*
24. GitLab refused to issue ID tokens for your project. Why, what attack does that
    protection kill, and why did pinning to the project ID fix it? *(L19)*
25. Prove the 13-service roll was zero-downtime — AFTER the fact, with nobody watching
    at the time. *(L19 — the metrics remember)*
28. Trivy gave mongo:3.4 a low score. Why is that BAD news, not good? *(L19 — EOL
    under-cataloguing; "a low score on an EOL image is blindness, not cleanliness")*

## E. Money & observability

4. Why does the budget have both ACTUAL and FORECASTED alerts? *(budget.tf / L1 cost
   story)*
27. The bill shows an EBS charge; `describe-volumes` returns empty. Reconcile. *(L19 —
    bill = month-to-date diary; API = live inventory)*

---

## The five sentences to own cold (not questions — ammunition)

- "An AWS account is a permissions boundary, not a network. IAM says whether I may;
  routing says whether I can."
- "A fresh task is not a fresh deployment."
- "The apply error is the only documentation that never goes stale."
- "My pipeline holds zero long-lived cloud credentials — each job federates its
  GitLab-signed identity into a role scoped to the project, and the credentials die
  with the job."
- "Scanning without a triage policy is noise — here is my accepted-risk register."
