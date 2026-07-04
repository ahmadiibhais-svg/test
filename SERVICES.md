# SERVICES.md — Sock Shop service specs (source of truth)

Extracted **from source**, not memory, on 2026-07-04 from a shallow clone of
`github.com/microservices-demo/microservices-demo`:
- `deploy/kubernetes/complete-demo.yaml` (K8s manifest — designated source of truth per CLAUDE.md)
- `deploy/docker-compose/docker-compose.yml` (container definition — closest analog to how we run on ECS)
- `deploy/kubernetes/helm-chart/templates/catalogue-dep.yaml` (for the catalogue `-DSN` flag)

This file overrides any assumption elsewhere (including VERIFY flags in the skill). Where the
two manifests disagree, the disagreement and the chosen value are documented below.

---

## Resolution of the skill's VERIFY flags

| VERIFY flag (skill) | Resolved value | Source |
|---|---|---|
| front-end port `8079 (VERIFY)` | **8079** — containerPort 8079; liveness/readiness `GET /` on 8079; K8s Service maps 80→8079 | complete-demo.yaml:277,291,316 |
| catalogue DSN flag/env | **`-DSN=<user>:<pass>@tcp(<host>:3306)/socksdb`** — a command-line **arg** to `/app`, not an env var. Upstream default `catalogue_user:default_password@tcp(catalogue-db:3306)/socksdb` | helm-chart/catalogue-dep.yaml:28 |
| user mongo env | **`MONGO_HOST=user-db:27017`** (compose, image user:0.4.4). ⚠️ K8s manifest instead uses env name `mongo` with image user:0.4.7 — see Decision D6 | docker-compose.yml:154-155 vs complete-demo.yaml:788-790 |
| carts-db / orders-db image | **`mongo:3.4`** (compose, pinned). ⚠️ K8s manifest uses untagged `mongo` (= latest) — see Decision D5 | docker-compose.yml:60,86 vs complete-demo.yaml:94,408 |

---

## Service table (chosen values)

Legend: **SC name** = ECS Service Connect discovery name (must equal the hostname baked into the
images). **ALB?** = attached to the public ALB. Fargate sizing per CLAUDE.md (Java = 0.5 vCPU/1024 MB, else 0.25/512).

| # | Service | Image (chosen) | Port(s) | Health check | Env | Secrets (SSM) | Depends on | SC name | ALB? | Fargate |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | front-end | weaveworksdemos/front-end:0.3.12 | **8079** | `GET / :8079` | `SESSION_REDIS=true` (only if session-db added, D3) | — | catalogue, carts, orders, user (:80); session-db (:6379) | front-end | **YES** | 0.25/512 |
| 2 | catalogue | weaveworksdemos/catalogue:0.3.5 | 80 | `GET /health :80` | args `-port=80 -DSN=…` | RDS DSN (host+user+pass) | RDS MySQL (:3306) | catalogue | no | 0.25/512 |
| 3 | carts | weaveworksdemos/carts:0.4.8 | 80 | Spring `/health` (not probed in manifest) | `JAVA_OPTS` | — | carts-db (:27017) | carts | no | **0.5/1024** |
| 4 | orders | weaveworksdemos/orders:0.4.7 | 80 | Spring `/health` (not probed) | `JAVA_OPTS` | — | orders-db (:27017); carts, user, payment, shipping (:80) | orders | no | **0.5/1024** |
| 5 | shipping | weaveworksdemos/shipping:0.4.8 | 80 | Spring `/health` (not probed) | `JAVA_OPTS` | — | rabbitmq (:5672) | shipping | no | **0.5/1024** |
| 6 | queue-master | weaveworksdemos/queue-master:0.3.1 | 80 | none | `JAVA_OPTS` | — | rabbitmq (:5672) | queue-master | no | **0.5/1024** |
| 7 | payment | weaveworksdemos/payment:0.4.3 | 80 | `GET /health :80` | — | — | — | payment | no | 0.25/512 |
| 8 | user | weaveworksdemos/user:0.4.4 | 80 | `GET /health :80` | `MONGO_HOST=user-db:27017` | — | user-db (:27017) | user | no | 0.25/512 |
| 9 | user-db | weaveworksdemos/user-db:0.4.0 | 27017 | none | — | — | — | user-db | no | 0.25/512 |
| 10 | carts-db | mongo:3.4 | 27017 | none | — | — | — | carts-db | no | 0.25/512 |
| 11 | orders-db | mongo:3.4 | 27017 | none | — | — | — | orders-db | no | 0.25/512 |
| 12 | rabbitmq | rabbitmq:3.6.8 | 5672 | none | — | — | — | rabbitmq | no | 0.25/512 |
| 13 | **session-db** *(accepted → D4 in DECISIONS.md)* | redis:alpine | 6379 | none | — | — | — | session-db | no | 0.25/512 |
| — | catalogue-db | **REPLACED by RDS MySQL** db.t4g.micro | 3306 | RDS | `MYSQL_DATABASE=socksdb` | master password → SSM SecureString | — | RDS endpoint (not SC) | no | RDS |
| — | edge-router | **DROPPED** — ALB replaces it | — | — | — | — | — | — | — | — |
| — | user-sim | weaveworksdemos/load-test:0.1.1 | — | — | — | — | — | not a service; on-demand `run-task` load generator: `-d 300 -r 200 -c 5 -h <ALB-DNS>` | no | — |

`JAVA_OPTS = -Xms64m -Xmx128m -XX:+UseG1GC -Djava.security.egd=file:/dev/urandom -Dspring.zipkin.enabled=false`
(applies to carts, orders, shipping, queue-master — from compose; without it they run slow/chatty and try to reach Zipkin.)

---

## Key facts baked into the images (do not fight these)

- **Bare-hostname service discovery.** front-end and the Java services call dependencies by bare
  hostname on port 80 (e.g. `http://catalogue/`, `http://carts/`). This is why the Service Connect
  discovery name **must exactly equal** the service name — there is no config knob to change it.
- **catalogue connects to MySQL via the `-DSN` arg only.** No env var. To point it at RDS we pass
  `-DSN=<user>:<pass>@tcp(<rds-endpoint>:3306)/socksdb` as container args. The password half must
  come from SSM (injected), so the DSN is assembled at task launch — flagged for the ecs-service module.
- **user-db re-seeds on every start** (seed users baked into `weaveworksdemos/user-db`). Ephemeral is fine.
- **queue-master** mounts `/var/run/docker.sock` in compose — **do NOT replicate on Fargate** (not possible/needed). It runs fine without it for the demo; document this.
- **rabbitmq**: compose uses plain `rabbitmq:3.6.8` (AMGP :5672 only). The K8s manifest uses
  `rabbitmq:3.6.8-management` + a `kbudde/rabbitmq-exporter` sidecar **for Prometheus**. We use
  CloudWatch, not Prometheus → we use plain `rabbitmq:3.6.8`, port 5672 only. Simpler, one container.
- **catalogue-db seed**: `dump.sql` lives in the separate `microservices-demo/catalogue` repo under
  `docker/catalogue-db/data/`. Fetch it in Phase 2 to seed RDS. Verify seed with a count on the `sock` table.

---

## Discrepancies between the two manifests + open decisions

These came out of the "verify from source" pass and need a call before Phase 1/2. Recommendations
carry into DECISIONS.md (D4–D6) once signed off. **All three accepted 2026-07-04 — logged in DECISIONS.md.**

**D4 — session-db (Redis): the biggest finding. ✅ ACCEPTED — logged in DECISIONS.md.**
The K8s manifest deploys a `session-db` (redis:alpine, :6379) and sets `SESSION_REDIS=true` on
front-end; the compose file has **neither** (single front-end, in-memory sessions). We plan to run
**front-end at desired_count 2 behind the ALB**. With in-memory sessions, two tasks don't share
login/cart state — a task failover or ALB round-robin drops the user's session, which is exactly the
fault-tolerance scenario we want to *demonstrate working*, not breaking.
- **Recommended:** add `session-db` (redis:alpine) as a 13th service + SC name `session-db`, keep
  `SESSION_REDIS=true`. Clean HA story: "shared session store so horizontal front-end scaling and
  failover keep the user logged in." (This adds one SC name to the locked list — flagged explicitly.)
- **Alternative:** drop `SESSION_REDIS`, run in-memory, enable ALB sticky sessions (cookie). Cheaper
  by one task but weaker failover story (sticky cookie pins you to a task that may die).

**D5 — Mongo image tag. ✅ ACCEPTED.** K8s uses untagged `mongo` (= latest, Mongo 7/8); old Spring Data
Mongo in carts/orders (0.4.x, ~2018) is not reliable against modern Mongo wire protocol.
- **Chosen:** pin **`mongo:3.4`** (compose) — the version sock-shop was built against. Known-good.

**D6 — user service version + mongo env. ✅ ACCEPTED.** compose = `user:0.4.4` + `MONGO_HOST=user-db:27017`;
K8s = `user:0.4.7` + env name `mongo`. Either resolves to host `user-db`, and our SC name is `user-db`,
so it connects even with no env at all.
- **Chosen:** **`user:0.4.4` + `MONGO_HOST=user-db:27017`** (matches the pinned compose set and
  the skill's locked map; avoids the ambiguous `mongo` env-name path).

**Net effect on the ECR/bootstrap count:** distinct images to mirror = 12 (carts-db and orders-db
share the single `mongo:3.4` image). Counting **one ECR repo per service name** for clean per-service
pipeline + task-def wiring gives **13 repos** (the 12 in CLAUDE.md + `session-db` per accepted D4).
