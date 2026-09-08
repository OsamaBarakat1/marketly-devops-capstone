# DevOps Capstone Project

## 1. What is this project?

You're given a working **microservices e-commerce app** — three independent
backend services (auth, catalog, orders) plus a React frontend. Your job is
**everything around the app**: take it from "runs on my laptop" to a fully
automated deployment on real AWS infrastructure, provisioned entirely by
Terraform, running on a Kubernetes cluster you build yourself on EC2, with a
GitHub Actions pipeline that ships every code change automatically.

Nobody hands you a managed Kubernetes service here. There's no EKS button to
click. You provision plain EC2 instances and turn them into a Kubernetes
cluster yourselves with `k3s` (a lightweight, fully-conformant Kubernetes
distribution). That's intentional — it's harder than clicking "create
cluster," and it's exactly the kind of work that teaches you what Kubernetes,
load balancers, and networking actually do underneath the abstraction.

**The app code is done. Your assignment is infrastructure, automation, and
operations.**

See [`docs/aws-architecture.png`](./docs/aws-architecture.png) for the full
diagram referenced throughout this document.

## 2. Architecture at a glance

```
GitHub push → GitHub Actions (CI) → builds 4 Docker images → pushes to ECR
                                                                    │
GitHub Actions (CD, self-hosted runner on the k3s control-plane) ──┘
        │ kubectl apply
        ▼
┌────────────────────────────── AWS VPC (10.0.0.0/16) ───────────────────────────────┐
│                                                                                     │
│   Internet ── Internet Gateway ── Application Load Balancer (2 AZs, public subnets)│
│                                          │ NodePort                                │
│                       ┌──────────────────┼──────────────────┐                     │
│                  k3s control-plane   k3s worker (ASG)   k3s worker (ASG)           │
│                  (private subnet)    (private subnet)   (private subnet, 2-4x)     │
│                       │                                                            │
│                       └──────────────► Amazon RDS (PostgreSQL, private subnet)     │
│                                                                                     │
│   Private subnets reach the internet (to pull images from ECR) via a NAT Instance  │
│   sitting in the public subnet — not a paid NAT Gateway.                           │
└─────────────────────────────────────────────────────────────────────────────────────┘

Amazon S3 — holds Terraform remote state, with a DynamoDB lock table (outside the VPC)
Amazon ECR — 4 image repositories: auth-service, catalog-service, orders-service, frontend
```

Why this shape, specifically:

- **No EKS.** EKS charges ~$0.10/hour (~$73/month) just for the control plane
  to exist, before you run a single pod. Running Kubernetes yourself on
  free-tier EC2 instances costs nothing extra and teaches you what EKS hides.
- **NAT Instance, not NAT Gateway.** A managed NAT Gateway costs ~$0.045/hour
  plus data processing fees, billed continuously. A `t3.micro` EC2 instance
  configured as a NAT does the same job and fits in the free tier.
- **RDS instead of SQLite.** The app currently stores data in local SQLite
  files. That works fine on one laptop, but breaks the moment you have
  multiple Kubernetes pods/EC2 workers — each one would have its own
  disconnected copy of the data. Migrating each service to PostgreSQL on RDS
  is part of your assignment (see §5.6) — it's the most realistic "this
  actually breaks in production" lesson in the whole project.
- **Self-hosted GitHub Actions runner on the control-plane instance**, instead
  of exposing the Kubernetes API to the internet or wiring up a VPN. The
  runner lives inside your VPC, already has `kubectl` configured, and GitHub
  Actions jobs execute on it directly — no public API endpoint needed.

## 3. What's provided vs. what you build

| Provided & working | Built for this project |
|---|---|
| `services/auth-service/` (Flask + SQLite + JWT) | `services/*/Dockerfile`, `frontend/Dockerfile` |
| `services/catalog-service/` (Flask + SQLite) | `terraform/` — root files + 8 modules |
| `services/orders-service/` (Flask + SQLite, calls catalog-service) | `k8s/**/*.yaml` |
| `frontend/` (React/Vite SPA) | `.github/workflows/*.yml` |
| | `scripts/*.sh` |
| | RDS migration for each service (code change) |

## 4. Where to start — order of operations

Don't jump straight to Terraform. Do these in order; each phase depends on
the previous one actually working.

1. **Run the app locally exactly as provided** (no Docker, no AWS) — confirms
   your baseline before you change anything. See §5.1.
2. **Containerize everything** — write the 4 Dockerfiles, get them running
   together with a Compose file you write yourself. See §5.2.
3. **Migrate each service from SQLite to PostgreSQL**, tested locally against
   a Postgres container first — before RDS even exists. See §5.6.
4. **Write the Terraform modules**, bottom-up: networking first
   (vpc → security-groups → nat-instance), then compute/data
   (ec2-cluster, rds, alb, ecr), then iam-oidc last. See §5.3.
5. **Bring the k3s cluster up manually** via SSM Session Manager and confirm
   `kubectl get nodes` works before writing a single YAML manifest. See §5.5.
6. **Write the Kubernetes manifests** and deploy by hand with `kubectl apply`.
   Get the app fully working in the cluster before automating anything.
7. **Wire up GitHub Actions** last — CI first (build/push images), then CD
   (deploy). Automating a pipeline for something that doesn't work manually
   yet just hides where the real problem is.
8. **Write the Bash scripts** (`setup.sh`, `deploy.sh`, `healthcheck.sh`,
   `teardown.sh`) — by this point you already know the exact commands; you're
   just making them repeatable.

## 5. Step-by-step per tool

### 5.1 Linux & Bash — first, before anything else

Run the app locally with nothing but Python and Node, to know what "working"
looks like:

```bash
cd services/auth-service && python -m venv venv && source venv/bin/activate && pip install -r requirements.txt && python app.py
cd services/catalog-service && python -m venv venv && source venv/bin/activate && pip install -r requirements.txt && python app.py
cd services/orders-service && python -m venv venv && source venv/bin/activate && pip install -r requirements.txt && python app.py
cd frontend && npm install && npm run dev
```

The four scripts in `scripts/` automate the rest. Each uses
`set -euo pipefail`, takes `--help`, and exits non-zero on failure.

- **`setup.sh`** — checks the eight CLIs the other scripts shell out to
  (`aws`, `terraform`, `kubectl`, `docker`, `git`, `curl`, `envsubst`,
  `python3`), that Terraform is at least 1.6 and the AWS CLI is v2, that the
  Docker daemon is up, and that AWS credentials resolve. Missing tools are
  fatal; missing configuration is reported as a warning, because a fresh
  clone legitimately has none yet.

  ```bash
  scripts/setup.sh
  ```

- **`deploy.sh`** — `terraform apply`, then the cluster half: it discovers
  the registry, database and load balancer from AWS, reads the signing key
  and admin password from SSM and the database password from Secrets
  Manager, renders the manifests, applies them and waits for all four
  rollouts. `.github/workflows/deploy.yml` calls this same script rather
  than repeating the logic, so CI exercises exactly what you run by hand.

  ```bash
  scripts/deploy.sh                      # infrastructure, then deploy HEAD
  scripts/deploy.sh --skip-terraform     # deploy only
  scripts/deploy.sh --tag <sha> --yes    # redeploy an earlier image
  ```

- **`healthcheck.sh`** — the first thing to run when something is broken.
  Four layers, checked from the inside out so the output says *which* one
  failed: nodes, deployments, each backend's `/health` through a
  port-forward, then a request through the load balancer.

  ```bash
  scripts/healthcheck.sh
  ```

- **`teardown.sh`** — shows the destroy plan, then asks you to type the
  project prefix rather than `y`, because this deletes a database. Run it at
  the end of every work session — see §7 on cost.

  ```bash
  scripts/teardown.sh
  ```

**One thing to know about the last two:** the k3s API server has no public
address and there is no SSH key, so `deploy.sh`'s cluster half and all of
`healthcheck.sh` only work from inside the VPC — on the control-plane
instance, reached over SSM. Both scripts detect this and print the exact
`aws ssm start-session` command rather than failing halfway. The Terraform
half of `deploy.sh` runs fine from a laptop.

### 5.2 Docker

One Dockerfile per component (`services/auth-service/Dockerfile`,
`services/catalog-service/Dockerfile`, `services/orders-service/Dockerfile`,
`frontend/Dockerfile`).

- The 3 backend services are plain Python/Flask — a simple `python:3.12-slim`
  base, `pip install -r requirements.txt`, `CMD ["python", "app.py"]` is
  enough to start; consider `gunicorn` for anything closer to production.
- The frontend needs **two stages**: a `node` stage that runs
  `npm run build` to produce static files, and an `nginx` (or similar) stage
  that just serves the built output. This keeps the final image small — it
  doesn't need Node.js inside it at all.
- Write a `docker-compose.yml` (anywhere you like, e.g. repo root) that brings
  up all 4 containers plus a `postgres` container, so you can test the full
  stack — including the RDS migration from §5.6 — before any of it touches
  AWS.

### 5.3 Terraform — organized into modules

`terraform/` root files (`main.tf`, `variables.tf`, `outputs.tf`,
`providers.tf`, `versions.tf`, `backend.tf`, `terraform.tfvars.example`) wire
together 8 modules under `terraform/modules/`. Build them in this order —
each one depends on outputs from the one before it:

| Order | Module | What it provisions |
|---|---|---|
| 0 | *(manual, one-time)* | S3 bucket + DynamoDB table for remote state — bootstrap this by hand or with a tiny separate config before `backend.tf` can use it |
| 1 | `modules/vpc` | VPC, 2 public + 2 private subnets across 2 AZs, Internet Gateway, public + private route tables |
| 2 | `modules/security-groups` | `alb-sg`, `k3s-sg`, `rds-sg`, `nat-sg` (see §5.4 for exact rules) |
| 3 | `modules/nat-instance` | EC2 NAT instance in a public subnet; private route table points its `0.0.0.0/0` route at this instance's network interface |
| 4 | `modules/ecr` | 4 ECR repositories — one per component |
| 5 | `modules/ec2-cluster` | The k3s control-plane EC2 instance + a Launch Template/Auto Scaling Group for worker nodes. Uses the two `.sh.tpl` files in `modules/ec2-cluster/templates/` as `user_data` (via Terraform's `templatefile()`) to bootstrap k3s automatically on boot |
| 6 | `modules/rds` | PostgreSQL instance (`db.t3.micro`), DB subnet group spanning both private subnets, parameter group |
| 7 | `modules/alb` | Application Load Balancer + target group (type `instance`) attached to the ASG, listener on port 80 forwarding to the NodePort your Ingress controller listens on |
| 8 | `modules/iam-oidc` | GitHub OIDC provider + IAM role trusted only by your specific repo, scoped to exactly what CI/CD needs (ECR push, EC2 describe, SSM) |

Root `main.tf` calls each module and passes outputs from earlier ones as
inputs to later ones — e.g. `modules/ec2-cluster` needs the private subnet
IDs from `modules/vpc` and the security group ID from
`modules/security-groups`.

### 5.4 AWS networking — what each piece is actually for

This is the part students usually click through without understanding on a
console tutorial. Here, you're writing it as code, so know what each line
does:

- **VPC** — your own private network inside AWS, isolated from every other
  AWS customer. Everything else lives inside it.
- **Subnets** — subdivisions of the VPC tied to one Availability Zone each. A
  subnet is "public" or "private" purely by which route table it's
  associated with — there's no special "public subnet" resource type.
- **Internet Gateway (IGW)** — attaches to the VPC and is the only thing that
  lets traffic in/out to the public internet at all. A subnet is "public"
  because its route table sends `0.0.0.0/0` traffic to the IGW.
- **Route Tables** — literally just a list of "if traffic is going to X, send
  it to Y." Your public route table says "internet-bound traffic → IGW."
  Your private route table says "internet-bound traffic → NAT instance."
- **NAT (Instance)** — lets resources in private subnets (your k3s nodes)
  reach the internet (to pull images from ECR, install packages) **without**
  being reachable *from* the internet. A managed NAT Gateway does this too,
  but bills hourly; a plain EC2 instance with IP forwarding enabled does the
  identical job for free-tier cost.
- **Security Groups** — stateful virtual firewalls attached to resources
  (not subnets). You need four: `alb-sg` (allow 80/443 from anywhere),
  `k3s-sg` (allow NodePort range only from `alb-sg`, nothing from the public
  internet), `rds-sg` (allow 5432 only from `k3s-sg`), `nat-sg` (allow
  traffic from inside the VPC CIDR only). Each one only opens exactly what
  the next layer needs — never wider.

### 5.5 AWS compute/data — EC2, ASG, ALB, RDS, S3

- **EC2** — the actual virtual machines. One runs the k3s control-plane (the
  Kubernetes "brain" — API server, scheduler, etcd); the rest are workers
  that actually run your application's containers.
- **Auto Scaling Group (ASG)** — manages the worker EC2 instances as a group:
  keeps a minimum count running, replaces any that fail health checks, and
  can scale out under load. The ALB's target group attaches to the ASG
  directly, so new workers register themselves automatically — you never
  manually add an instance to the load balancer.
- **Application Load Balancer (ALB)** — the single public entry point.
  Forwards incoming HTTP traffic to a NodePort that's open on every k3s node
  (control-plane and workers alike), where your Ingress controller picks it
  up and routes it to the right service inside the cluster.
- **Amazon RDS** — managed PostgreSQL. You don't manage patching, backups, or
  the underlying OS — you just get a connection string. This is where each
  service's data lives once you complete the SQLite → Postgres migration
  (§5.6), since it's reachable from every worker node identically, unlike a
  local SQLite file that only exists on one machine.
- **Amazon S3** — object storage, used here for one thing outside the VPC
  entirely: Terraform's remote state file, so state isn't just sitting on one
  person's laptop. A DynamoDB table alongside it serializes concurrent runs.
  Database backups are *not* shipped here — `modules/rds` sets
  `backup_retention_period = 7`, which is RDS's own automated snapshots.

Bring the cluster up and confirm it manually before writing any Kubernetes
YAML:

```bash
# Connect to the control-plane instance with no SSH key, no bastion, no public IP:
aws ssm start-session --target <control-plane-instance-id>

# On the instance, once k3s is installed (your user-data script does this):
sudo k3s kubectl get nodes
```

### 5.6 Migrating SQLite → RDS PostgreSQL (required)

Each service currently opens a local `sqlite3` file. That's fine for one
process on one laptop. It silently breaks the moment you run 2+ replicas
across different EC2 workers — each pod gets its own empty/divergent SQLite
file, and "my order disappeared" bugs start happening that look random but
aren't.

For each of the 3 services:

1. Add `psycopg2-binary` to `requirements.txt`.
2. Replace the `sqlite3.connect(...)` calls with a Postgres connection,
   driven by a `DATABASE_URL` (or `DB_HOST`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`)
   environment variable — don't hardcode RDS's endpoint into code.
3. Adjust SQL syntax differences where they exist (e.g. `SERIAL` vs
   SQLite's `AUTOINCREMENT` — Postgres uses `SERIAL`/`GENERATED ... AS
   IDENTITY`).
4. Test against a local `postgres` Docker container before pointing
   anything at RDS.
5. In Kubernetes, inject the RDS endpoint and credentials via a
   ConfigMap + Secret (see `k8s/*/secret.yaml`) — never commit real
   credentials to git.

### 5.7 Kubernetes (k3s)

`k8s/` is organized per-component, mirroring the 4 things you deploy:

```
k8s/
  namespace.yaml
  ingress.yaml         routes by path to each service via Traefik (bundled with k3s)
  hpa.yaml              autoscale at least one Deployment by CPU
  auth-service/      deployment.yaml, service.yaml, secret.yaml
  catalog-service/   deployment.yaml, service.yaml
  orders-service/    deployment.yaml, service.yaml, secret.yaml
  frontend/          deployment.yaml, service.yaml
```

Build order:

1. `namespace.yaml` first — everything else lives in it.
2. `catalog-service/` — no dependencies on the other two services, easiest
   to get right first.
3. `auth-service/` — needs its `secret.yaml` to define `SHARED_SECRET`.
4. `orders-service/` — needs the **same** `SHARED_SECRET` value as
   auth-service (it verifies JWTs locally without calling back to
   auth-service — if the secrets don't match, every order request will
   return 401, which is the point: this teaches you to trace an auth failure
   across services).
5. `frontend/`.
6. `ingress.yaml` once all 4 Services exist, so it has something to route to.
   Service type should be `ClusterIP`, with the Ingress (Traefik) exposed via
   a `NodePort` Service — that NodePort is what the ALB's target group points
   at.
7. `hpa.yaml` last, once the app is stable enough to load-test.

Every Deployment needs readiness/liveness probes against `/health` and
resource requests/limits — workers are small (`t3.micro`), so an unbounded
pod can starve its neighbors.

### 5.8 CI/CD — GitHub Actions

Four workflows in `.github/workflows/`:

1. **`ci.yml`** — on PR and push to `main`. The test job brings the whole
   stack up with `docker compose` and drives a real purchase end to end:
   log in, read the catalog, place an order, assert the stock decremented.
   That is deliberate — the failures that matter here are *between* services
   (a token auth-service signs and orders-service rejects, a price read from
   the wrong source), and a unit test on one service catches none of them.
   On `main` it then builds all 4 images and pushes them to ECR via the OIDC
   role from `modules/iam-oidc` — **no static AWS access keys stored as
   GitHub secrets, ever.** Images are tagged by commit SHA only; the
   repositories are immutable, so there is no `:latest` to be vague about.
2. **`terraform.yml`** — `terraform plan` commented on every PR that touches
   `terraform/`; `terraform apply` on merge to `main`, also via OIDC. Apply
   is additionally gated on the `ENABLE_TERRAFORM_APPLY` variable, so merging
   a Terraform change can never start billing an account by surprise.
3. **`deploy.yml`** — runs on the **self-hosted runner** registered on the
   k3s control-plane instance (register it once, following GitHub's repo
   settings → Actions → Runners flow). It calls `scripts/deploy.sh` and
   `scripts/healthcheck.sh` rather than repeating their logic, so there is
   one implementation of the deploy and CI exercises the same code path you
   run by hand. Because the runner lives inside the VPC already
   authenticated to the cluster, the Kubernetes API is never exposed
   publicly and no kubeconfig is stored as a GitHub secret.
4. **`security.yml`** — gitleaks across the full commit history (a secret
   removed in a later commit is still a leak if an earlier one holds it), and
   tfsec over `terraform/`. This is the backstop for the `.githooks`
   pre-commit hook, which only protects clones that opted into it.

One subtlety in `deploy.yml` worth knowing: a `workflow_run` trigger checks
out the default branch tip by default, which may already be ahead of the
commit CI built. It pins the checkout to `workflow_run.head_sha` instead —
otherwise it would deploy an image tag that ECR does not have.

## 6. How everything connects (the full request/deploy lifecycle)

**A user request:** browser → ALB (public subnet, port 80) → target group →
NodePort on whichever k3s node Traefik landed on → Traefik routes by path to
the right ClusterIP Service → pod → (for orders) outbound call to
catalog-service's ClusterIP → (for any service) RDS over port 5432.

**A code change:** `git push` to `main` → `ci.yml` runs on GitHub-hosted
runners, builds + pushes images to ECR via OIDC → `deploy.yml` runs on the
self-hosted runner sitting on your control-plane EC2 instance → that runner
already has `kubectl` pointed at the local k3s cluster → it applies the
manifests with the new image tags → Kubernetes does a rolling update → ALB
health checks confirm the new pods are healthy before sending them traffic.

**Terraform's role in all of this:** it's the only thing that talks directly
to the AWS API. Everything above — the VPC, the EC2 instances, the ALB, RDS,
the OIDC trust relationship that lets GitHub Actions authenticate at all —
exists because Terraform created it. Nothing in `k8s/` or
`.github/workflows/` can do anything until `terraform apply` has run
successfully first.

## 7. Cost discipline

See the cost callout box in [`docs/aws-architecture.png`](./docs/aws-architecture.png).
Short version: this architecture is free-tier-eligible for the first 12
months of an AWS account if you **don't leave it running 24/7**. Run
`scripts/teardown.sh` at the end of every work session — RDS storage and S3
are the only things that keep costing anything (cents) while torn down, and
even those go away if you delete the RDS instance and empty the S3 bucket at
the very end of the project.

## 8. More detail

- [`PROJECT_BRIEF.md`](./PROJECT_BRIEF.md) — milestones, deliverables,
  submission checklist.
- [`RUBRIC.md`](./RUBRIC.md) — exact point breakdown.
- [`docs/architecture-diagram.md`](./docs/architecture-diagram.md) — what the
  diagram shows, and where it is deliberately simplified.
- [`docs/debugging-writeup.md`](./docs/debugging-writeup.md) — one thing that
  broke and how it was tracked down: an Nginx proxy caching a container
  address that another service had since been given.
- Each service and the frontend has its own `README.md` with exact run
  instructions and environment variables.
