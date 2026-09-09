# Marketly — a microservices storefront, deployed on self-managed Kubernetes on AWS

Marketly is a small e-commerce application — three Flask services (auth,
catalog, orders) and a React storefront — and everything needed to run it on
AWS: Terraform for the infrastructure, a k3s Kubernetes cluster built on plain
EC2 instances, and GitHub Actions pipelines that build, test and ship every
commit to `main`.

The application code was the starting point. The work in this repository is
what surrounds it: containerizing the four components, moving three services
off per-process SQLite onto a shared PostgreSQL instance, provisioning the
network, cluster and database as code, and automating the path from `git push`
to running pods.

There is no EKS here, and no managed NAT. The cluster is provisioned as bare
EC2 instances and turned into Kubernetes by a `user_data` script that installs
`k3s` — a lightweight, fully conformant distribution. That choice is
deliberate: it costs nothing beyond the instances themselves, and it leaves
the parts a managed control plane hides — bootstrap, join tokens, node
networking, how the load balancer actually reaches a pod — visible in the
repository rather than behind an API.

See [`docs/aws-architecture.png`](./docs/aws-architecture.png) for the full
diagram referenced throughout this document.

## 1. Architecture at a glance

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

- **No EKS.** EKS charges ~$0.10/hour (~$73/month) for the control plane to
  exist, before a single pod runs. Self-managed k3s on free-tier EC2 costs
  nothing extra.
- **NAT instance, not NAT Gateway.** A managed NAT Gateway bills ~$0.045/hour
  plus data processing, continuously. A `t3.micro` with IP forwarding enabled
  does the identical job inside the free tier.
- **RDS, not SQLite.** Each service originally opened a local SQLite file.
  That survives exactly one process on one machine; with two replicas on two
  workers, each pod gets its own divergent copy and orders start
  disappearing. §7 covers the migration.
- **Self-hosted GitHub Actions runner on the control-plane instance**, rather
  than exposing the Kubernetes API to the internet or building a VPN. The
  runner sits inside the VPC with `kubectl` already configured, so no public
  API endpoint and no kubeconfig-in-a-secret is needed.

## 2. Repository layout

| Path | What it holds |
|---|---|
| `services/auth-service/` | Flask + PostgreSQL + JWT — access tokens, rotating refresh cookies, account lockout |
| `services/catalog-service/` | Flask + PostgreSQL — products, categories, stock |
| `services/orders-service/` | Flask + PostgreSQL — checkout, priced and stock-checked against catalog-service |
| `frontend/` | React (Vite) + Tailwind single-page storefront |
| `docker-compose.yml`, `.env.example` | The whole stack plus PostgreSQL, locally |
| `terraform/` | Root configuration and 8 modules, plus `bootstrap/` for the state backend |
| `k8s/` | Namespace, ConfigMap, per-component Deployment/Service/Secret, Ingress, HPA |
| `.github/workflows/` | `ci.yml`, `terraform.yml`, `deploy.yml`, `security.yml` |
| `scripts/` | `setup.sh`, `deploy.sh`, `healthcheck.sh`, `teardown.sh` |
| `docs/` | Architecture diagram, a debugging write-up, and the original assignment brief |

## 3. Running it locally

The whole stack, including PostgreSQL, comes up with Compose:

```bash
cp .env.example .env      # optional; every value has a working default
docker compose up --build
```

The storefront is then on <http://localhost:5173>, and the three services on
5001–5003. Seeded accounts are `demo` / `demo1234` and `admin` / `admin1234`
— local development defaults only; the deployed admin password is generated
by Terraform and read from SSM Parameter Store at deploy time.

A single service can also be run directly against a Python virtualenv, which
is useful when iterating on one of them:

```bash
cd services/catalog-service
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
DATABASE_URL=postgresql://marketly:marketly_dev_password@localhost:5432/marketly python app.py
```

That path uses Flask's development server, and only that path. In containers
each service is served by **gunicorn** (`gthread` workers, `--preload` so the
schema bootstrap runs once in the master rather than once per worker).
auth-service deliberately runs a single worker with 8 threads: its login rate
limiter and account lockout keep counters in process memory, and a second
worker would quietly double both thresholds. catalog and orders hold no
per-process state and run 2 workers × 4 threads. Concurrency beyond that comes
from replicas, which is what the HPA adds.

## 4. The four scripts

Each uses `set -euo pipefail`, takes `--help`, and exits non-zero on failure.

- **`setup.sh`** — checks the eight CLIs the other scripts shell out to
  (`aws`, `terraform`, `kubectl`, `docker`, `git`, `curl`, `envsubst`,
  `python3`), that Terraform is at least 1.6 and the AWS CLI is v2, that the
  Docker daemon is up, and that AWS credentials resolve. Missing tools are
  fatal; missing configuration is a warning, because a fresh clone
  legitimately has none yet.

  ```bash
  scripts/setup.sh
  ```

- **`deploy.sh`** — `terraform apply`, then the cluster half: it discovers the
  registry, database and load balancer from AWS, reads the signing key and
  admin password from SSM and the database password from Secrets Manager,
  renders the manifests, applies them and waits for all four rollouts.
  `.github/workflows/deploy.yml` calls this same script rather than repeating
  the logic, so CI exercises exactly what runs by hand.

  ```bash
  scripts/deploy.sh                      # infrastructure, then deploy HEAD
  scripts/deploy.sh --skip-terraform     # deploy only
  scripts/deploy.sh --tag <sha> --yes    # redeploy an earlier image
  ```

- **`healthcheck.sh`** — the first thing to run when something is broken. Four
  layers, checked from the inside out so the output says *which* one failed:
  nodes, deployments, each backend's `/health` through a port-forward, then a
  request through the load balancer.

  ```bash
  scripts/healthcheck.sh
  ```

- **`teardown.sh`** — shows the destroy plan, then asks for the project prefix
  to be typed rather than `y`, because this deletes a database. See §11 on
  cost.

  ```bash
  scripts/teardown.sh
  ```

**One constraint on the last two:** the k3s API server has no public address
and there is no SSH key, so `deploy.sh`'s cluster half and all of
`healthcheck.sh` only work from inside the VPC — on the control-plane
instance, reached over SSM. Both scripts detect this and print the exact
`aws ssm start-session` command rather than failing halfway. The Terraform
half of `deploy.sh` runs fine from a laptop.

## 5. Containers

One Dockerfile per component. The three services share a shape:
`python:3.12-slim`, dependencies installed from a pinned
`requirements.txt`, a fixed numeric UID (`10001`) because Kubernetes cannot
verify `runAsNonRoot` against a username, and gunicorn as the entrypoint.

The frontend image is two-stage: a `node` stage runs `npm run build`, and an
`nginx` stage serves the resulting static files. Node never ships in the final
image.

`docker-compose.yml` wires all four against a `postgres` container with
health-gated `depends_on`, which is what makes the end-to-end test in CI
possible without any AWS resources.

## 6. Terraform

`terraform/` root files (`main.tf`, `variables.tf`, `outputs.tf`,
`providers.tf`, `versions.tf`, `backend.tf`, `terraform.tfvars.example`) wire
together 8 modules. Each depends on outputs from the ones above it:

| Order | Module | What it provisions |
|---|---|---|
| 0 | `terraform/bootstrap` | S3 bucket + DynamoDB table for remote state — applied once, on its own, before `backend.tf` can point at them |
| 1 | `modules/vpc` | VPC, 2 public + 2 private subnets across 2 AZs, Internet Gateway, public + private route tables |
| 2 | `modules/security-groups` | `alb-sg`, `k3s-sg`, `rds-sg`, `nat-sg` (rules in §8) |
| 3 | `modules/nat-instance` | EC2 NAT instance in a public subnet; the private route table's `0.0.0.0/0` points at its network interface |
| 4 | `modules/ecr` | 4 image repositories, one per component |
| 5 | `modules/ec2-cluster` | The k3s control-plane instance plus a Launch Template / Auto Scaling Group of workers. The two `.sh.tpl` files in `modules/ec2-cluster/templates/` are rendered with `templatefile()` as `user_data`, so k3s bootstraps on boot |
| 6 | `modules/rds` | PostgreSQL `db.t3.micro`, DB subnet group spanning both private subnets, parameter group |
| 7 | `modules/alb` | Application Load Balancer + `instance`-type target group attached to the ASG, listener on 80 forwarding to the Ingress NodePort |
| 8 | `modules/iam-oidc` | GitHub OIDC provider + an IAM role trusted only by this repository, scoped to what CI/CD needs (ECR push, EC2 describe, SSM) |

Root `main.tf` passes each module's outputs into the next — `ec2-cluster`
takes private subnet IDs from `vpc` and a security group ID from
`security-groups`, and so on.

## 7. From SQLite to PostgreSQL

Each service originally opened a local `sqlite3` file. That is fine for one
process on one laptop and silently wrong the moment 2+ replicas run on
different workers: each pod gets its own empty or divergent file, and "my
order disappeared" bugs appear that look random but aren't.

All three now speak PostgreSQL through `psycopg2`, against a `DATABASE_URL`
supplied by the environment — no endpoint is compiled in. Two details that
mattered more than the SQL translation:

- **Schema per service.** auth, catalog and orders each own a schema
  (`DB_SCHEMA`) on the one RDS instance, so a service cannot read or write
  another's tables even though the instance is shared. One `db.t3.micro`
  stays inside the free tier; three would not.
- **Startup under concurrency.** Every replica runs `init_db()` on boot,
  which SQLite's single process never had to survive. Each service takes a
  distinct `pg_advisory_xact_lock` before creating its schema and seeding, so
  concurrent replicas queue instead of racing — otherwise the catalog seed
  would be inserted once per replica. `init_db()` also retries for up to 60
  seconds against a database that isn't accepting connections yet, which is
  what a pod restarting before RDS is reachable looks like.

Credentials reach the pods as a Kubernetes Secret rendered at deploy time from
Secrets Manager; addresses and flags come from `k8s/configmap.yaml`. Nothing
real is committed.

## 8. AWS networking — what each piece is for

- **VPC** — a private network inside AWS, isolated from every other customer.
  Everything else lives in it.
- **Subnets** — subdivisions of the VPC, each tied to one Availability Zone. A
  subnet is "public" or "private" purely by which route table it is associated
  with; there is no special resource type for either.
- **Internet Gateway** — attaches to the VPC and is the only thing that lets
  traffic reach the public internet at all. A subnet is public because its
  route table sends `0.0.0.0/0` to the IGW.
- **Route tables** — a list of "traffic going to X goes to Y." The public one
  says internet-bound → IGW; the private one says internet-bound → NAT
  instance.
- **NAT instance** — lets the k3s nodes in private subnets reach out (ECR
  pulls, package installs) without being reachable *from* the internet. A
  managed NAT Gateway does the same and bills hourly; an EC2 instance with IP
  forwarding does it for free-tier cost.
- **Security groups** — stateful firewalls attached to resources, not subnets.
  Four of them: `alb-sg` (80/443 from anywhere), `k3s-sg` (the NodePort range
  from `alb-sg` only, nothing from the internet), `rds-sg` (5432 from `k3s-sg`
  only), `nat-sg` (from the VPC CIDR only). Each opens exactly what the next
  layer needs.

## 9. AWS compute and data

- **EC2** — one instance runs the k3s control plane (API server, scheduler,
  etcd); the rest are workers running the application's containers.
- **Auto Scaling Group** — keeps a minimum worker count alive, replaces failed
  instances, and scales out under load. The ALB's target group attaches to the
  ASG, so a new worker registers itself; no instance is ever added to the load
  balancer by hand.
- **Application Load Balancer** — the single public entry point. It forwards
  HTTP to a NodePort open on every k3s node, where Traefik picks it up.
- **Amazon RDS** — managed PostgreSQL, reachable identically from every
  worker, with `backup_retention_period = 7` for RDS's own automated
  snapshots.
- **Amazon S3** — one job, outside the VPC entirely: Terraform's remote state,
  with a DynamoDB table beside it to serialize concurrent runs. Database
  backups are not shipped here.

The cluster has no public IP and no SSH key. Access is:

```bash
aws ssm start-session --target <control-plane-instance-id>
sudo k3s kubectl get nodes
```

## 10. Kubernetes (k3s)

```
k8s/
  namespace.yaml
  configmap.yaml       non-secret config: service addresses, CORS origin, cookie flags
  ingress.yaml         path-based routing to each service via Traefik (bundled with k3s)
  hpa.yaml             CPU autoscaling for catalog-service, 2→5 replicas
  auth-service/      deployment.yaml, service.yaml, secret.yaml
  catalog-service/   deployment.yaml, service.yaml, secret.yaml
  orders-service/    deployment.yaml, service.yaml, secret.yaml
  frontend/          deployment.yaml, service.yaml
```

Services are `ClusterIP`; only Traefik is exposed, as a NodePort, and that
NodePort is what the ALB's target group points at. Every Deployment has
readiness and liveness probes against `/health` and resource requests and
limits — workers are `t3.micro`, so an unbounded pod starves its neighbours.

auth-service and orders-service must hold the *same* `SHARED_SECRET`:
orders-service verifies auth-service's JWTs locally rather than calling back,
so a mismatch turns every order request into a 401 with nothing obviously
wrong on either side.

The HPA targets catalog-service because every storefront page hits it and
orders-service calls it again per line item at checkout — it is read-heavy, so
extra replicas absorb load instead of contending over rows. It scales on 60%
of the CPU *request*, not the limit, and retreats on a 5-minute stabilization
window to avoid flapping.

## 11. CI/CD

1. **`ci.yml`** — on PR and push to `main`. The test job brings the whole
   stack up with `docker compose` and drives a real purchase end to end: log
   in, read the catalog, place an order, assert the stock decremented. That is
   deliberate — the failures that matter here are *between* services (a token
   auth signs and orders rejects, a price read from the wrong source), and a
   unit test on one service catches none of them. On `main` it then builds all
   4 images and pushes them to ECR via the OIDC role from `modules/iam-oidc` —
   **no static AWS access keys as GitHub secrets, ever.** Images are tagged by
   commit SHA only; the repositories are immutable, so there is no `:latest`
   to be vague about.
2. **`terraform.yml`** — `terraform plan` commented on every PR touching
   `terraform/`, `terraform apply` on merge to `main`, also over OIDC. Apply is
   additionally gated on the `ENABLE_TERRAFORM_APPLY` variable, so merging a
   Terraform change can never start billing an account by surprise.
3. **`deploy.yml`** — runs on the self-hosted runner registered on the
   control-plane instance. It calls `scripts/deploy.sh` and
   `scripts/healthcheck.sh` rather than duplicating them, so there is one
   implementation of a deploy. Because the runner is already inside the VPC
   and authenticated to the cluster, the Kubernetes API is never exposed and
   no kubeconfig is stored as a secret.
4. **`security.yml`** — gitleaks across the full commit history (a secret
   deleted in a later commit is still leaked by the earlier one), and tfsec
   over `terraform/`. This backstops the `.githooks` pre-commit hook, which
   only protects clones that opted in.

One subtlety in `deploy.yml`: a `workflow_run` trigger checks out the default
branch tip, which may already be ahead of the commit CI built. It pins the
checkout to `workflow_run.head_sha` instead — otherwise it would deploy an
image tag ECR does not have.

## 12. How everything connects

**A user request:** browser → ALB (public subnet, port 80) → target group →
NodePort on whichever k3s node Traefik landed on → Traefik routes by path to
the right ClusterIP Service → pod → (for orders) an outbound call to
catalog-service's ClusterIP → RDS over 5432.

**A code change:** `git push` to `main` → `ci.yml` on GitHub-hosted runners
builds and pushes images to ECR over OIDC → `deploy.yml` on the self-hosted
runner on the control-plane instance applies the manifests with the new image
tags → Kubernetes rolls the Deployments → ALB health checks confirm the new
pods before they take traffic.

**Terraform's role:** it is the only thing that talks to the AWS API. The VPC,
the instances, the ALB, RDS, and the OIDC trust that lets GitHub Actions
authenticate at all exist because Terraform created them. Nothing in `k8s/` or
`.github/workflows/` can do anything before `terraform apply` has succeeded.

## 13. Cost

See the cost callout in
[`docs/aws-architecture.png`](./docs/aws-architecture.png). The short version:
this architecture is free-tier-eligible for the first 12 months of an AWS
account provided it is not left running 24/7. `scripts/teardown.sh` at the end
of a work session leaves only RDS storage and S3 costing anything (cents), and
those go away too once the instance is deleted and the bucket emptied.

## 14. More detail

- [`docs/architecture-diagram.md`](./docs/architecture-diagram.md) — what the
  diagram shows, and where it is deliberately simplified.
- [`docs/debugging-writeup.md`](./docs/debugging-writeup.md) — one thing that
  broke and how it was tracked down: an Nginx proxy caching a container
  address that another service had since been given.
- Each service and the frontend has its own `README.md` with exact run
  instructions and environment variables.
- [`docs/assignment/`](./docs/assignment/) — the original capstone brief and
  grading rubric this project was built against.
