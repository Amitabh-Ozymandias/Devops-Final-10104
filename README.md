# SpendWise: Expense Tracker on a Full DevOps Pipeline

SpendWise is a small personal finance app. You record expenses (title, amount, category, date, notes), filter them by category, and see totals per category on a dashboard. The app itself is simple on purpose. The project is about the delivery pipeline around it: tests, containers, CI/CD with a security gate, AWS infrastructure as code, Kubernetes with Helm, and monitoring.

```
 git push ──► GitHub Actions ──► pytest + ruff ─┐
                                 npm build ─────┼─► docker build ─► Trivy scan ─► push to GHCR (:<sha>)
                                                                                      │
 Terraform ──► AWS VPC (2 public subnets) + EKS ◄── helm upgrade --install ◄──────────┘
                                                │
       Ingress (nginx) ── /     ──► frontend (React + Nginx) ×2
                       └─ /api  ──► backend (FastAPI) ×2 ──► PostgreSQL
                                          │ /metrics
                                  Prometheus ──► Grafana dashboard
```

| Layer | Technology | Location |
|---|---|---|
| Backend | FastAPI, SQLAlchemy 2, Alembic, PostgreSQL | [backend/](backend/) |
| Frontend | React 18 + Vite, served by unprivileged Nginx | [frontend/](frontend/) |
| Tests | pytest + in-memory SQLite, ruff lint | [backend/tests/](backend/tests/) |
| Containers | Multi-stage Dockerfiles, non-root, Docker Compose | [docker-compose.yml](docker-compose.yml) |
| CI/CD | GitHub Actions → GHCR (commit-SHA tags) → EKS | [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) |
| Security | Trivy image scan, fails on HIGH/CRITICAL | same workflow |
| Infrastructure | Terraform: VPC + EKS + managed node group | [terraform/](terraform/) |
| Orchestration | Kubernetes namespace + Helm chart + Ingress | [k8s/](k8s/), [helm/spendwise/](helm/spendwise/) |
| Observability | kube-prometheus-stack (Prometheus + Grafana) | [monitoring/](monitoring/) |

---

## 1. Application

### API

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness check |
| GET | `/health/ready` | Readiness check (pings the database) |
| GET | `/metrics` | Prometheus metrics |
| GET | `/api/expenses?category=Food` | List expenses, with an optional category filter |
| GET | `/api/expenses/summary` | Totals and counts per category |
| GET | `/api/expenses/{id}` | Get one expense |
| POST | `/api/expenses` | Create an expense |
| PUT | `/api/expenses/{id}` | Update an expense (partial fields allowed) |
| DELETE | `/api/expenses/{id}` | Delete an expense |

Interactive docs are at `http://localhost:8000/docs` when the stack is running.

The schema lives in one Alembic migration, [backend/alembic/versions/0001_create_expenses_table.py](backend/alembic/versions/0001_create_expenses_table.py). The container entrypoint runs `alembic upgrade head` on startup. A PostgreSQL advisory lock makes sure only one replica migrates at a time.

### Run locally with Docker Compose

```bash
docker compose up --build
```

- Frontend: http://localhost:3000
- Backend: http://localhost:8000/health and http://localhost:8000/docs

To override the default database credentials, copy `.env.example` to `.env` and edit it.

### Run tests

```bash
cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
ruff check .
pytest -v
```

The tests use an in-memory SQLite database. [backend/tests/conftest.py](backend/tests/conftest.py) sets this up by overriding the `get_db` dependency, so the tests never touch PostgreSQL. There are 13 tests covering health, metrics, and every expense endpoint, including validation and 404 cases.

---

## 2. CI/CD pipeline

[.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) runs on every push and pull request to `main`:

1. **backend-tests**: `ruff check` followed by `pytest`. A failing test fails the job, and every later job is skipped.
2. **frontend-build**: `npm ci && npm run build`.
3. **images** (matrix: backend, frontend):
   - `docker build`
   - **Trivy** scan with `--severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed`. Any fixable HIGH or CRITICAL CVE fails the pipeline before the image is pushed.
   - Push to `ghcr.io/<owner>/spendwise-<service>:<git-commit-sha>`. Images are never tagged `latest`.
4. **deploy** (opt-in): `helm upgrade --install` on EKS with `global.imageTag=<sha>`.

Trivy runs as a pinned container image (`aquasec/trivy:0.58.1`) instead of through a third-party action. This keeps the scanner version fixed and auditable.

### Enabling the deploy job

In the GitHub repository, under **Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | IAM user that can access the cluster |
| Secret | `POSTGRES_PASSWORD` | Database password used in the cluster |
| Variable | `DEPLOY_ENABLED` | `true` |
| Variable | `AWS_REGION` | e.g. `us-east-1` |
| Variable | `EKS_CLUSTER_NAME` | `spendwise-eks` |

After the first pipeline run, open both packages under **GitHub → Packages** and set their visibility to **Public**. Otherwise the cluster cannot pull them. The alternative is to create a pull secret and set `global.imagePullSecrets`.

---

## 3. Security scan (Trivy)

Trivy scans the OS packages (Debian for the backend, Alpine for the frontend) and the language dependencies (Python wheels, npm packages) of each built image. It checks them against public CVE databases. The pipeline only fails on HIGH or CRITICAL issues that have a fix available. Both Dockerfiles run `apt-get upgrade` or `apk upgrade` to pull in OS patches, so a clean scan means no known, fixable, serious vulnerability in either image at build time. If a CVE shows up, the Trivy table names the package, the installed version, and the fixed version. The fix is to bump that dependency or the base image.

**A real finding from this project.** The first scan of the backend image failed with 3 HIGH CVEs in `starlette` 0.41.3, the web framework underneath FastAPI. One was **CVE-2025-62727**: an attacker could send a crafted HTTP `Range` header that makes Starlette merge byte ranges inefficiently, which burns CPU (a denial of service). Trivy reported that version 0.49.1 fixes it. Upgrading to FastAPI 0.143.0 / Starlette 1.7.0 (and `prometheus-fastapi-instrumentator` 8.1.0, which supports Starlette 1.x) brought the scan to `Total: 0 (HIGH: 0, CRITICAL: 0)`.

---

## 4. Infrastructure (Terraform → AWS)

[terraform/](terraform/) uses the official `terraform-aws-modules` to create:

- A **VPC** (`10.20.0.0/16`) with **2 public subnets** in two availability zones, tagged for AWS load balancers. There is no NAT gateway, which keeps costs low.
- An **EKS cluster** (Kubernetes 1.33) with one **managed node group** of 2 × `t3.medium`.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # git-ignored
aws configure                                  # credentials stay on your machine
terraform init
terraform plan
terraform apply                                # ~15 minutes
$(terraform output -raw configure_kubectl)     # point kubectl at the cluster
```

> **Cost warning.** The EKS control plane and nodes are billed hourly. Tear everything down when you finish:
> ```bash
> ./scripts/teardown.sh   # uninstalls Helm releases (removes the NLB), then terraform destroy
> ```

---

## 5. Kubernetes + Helm

```bash
# One command: namespaces, Prometheus/Grafana, ingress-nginx and the app
./scripts/bootstrap-cluster.sh <your-github-user-lowercase> <commit-sha>

# Or step by step
kubectl apply -f k8s/namespace.yaml
helm upgrade --install spendwise helm/spendwise -n spendwise \
  --set global.imageRegistry=ghcr.io/<owner> --set global.imageTag=<sha>

kubectl get pods -n spendwise
kubectl get svc -n spendwise
helm list -n spendwise
kubectl get ingress -n spendwise
```

The chart ([helm/spendwise/](helm/spendwise/)) deploys:

- The backend Deployment (2 replicas) with startup, liveness, and readiness probes, plus a ClusterIP Service.
- The frontend Deployment (2 replicas) and its ClusterIP Service.
- A PostgreSQL StatefulSet and Service, with credentials in a Secret.
- An Ingress that routes `/api` to the backend and `/` to the frontend.
- A ServiceMonitor and a Grafana dashboard ConfigMap.

All pods run as non-root with every Linux capability dropped.

---

## 6. Observability

- The backend exposes `/metrics` through `prometheus-fastapi-instrumentator`. That covers `http_requests_total` and `http_request_duration_seconds`, plus a custom `spendwise_expenses_created_total{category}`.
- `kube-prometheus-stack` ([monitoring/kube-prometheus-stack-values.yaml](monitoring/kube-prometheus-stack-values.yaml)) installs Prometheus and Grafana. Prometheus finds the app through the chart's ServiceMonitor.
- Grafana's sidecar loads the **SpendWise - API Overview** dashboard automatically. It shows request rate, 5xx error rate, p50/p95/p99 latency, responses by status, and expenses created per category.

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# http://localhost:9090/targets  → serviceMonitor/spendwise/spendwise-backend is UP

kubectl port-forward -n monitoring svc/monitoring-grafana 3001:80
# http://localhost:3001  (admin / spendwise-admin) → Dashboards → SpendWise - API Overview
```

---

## 7. Live demo script

1. Show the app at the Ingress URL and add a few expenses.
2. Make a visible change, for example the subtitle in [frontend/src/App.jsx](frontend/src/App.jsx).
3. `git commit -am "Update dashboard subtitle" && git push`
4. Watch GitHub Actions run tests, build, Trivy, the GHCR push, and the deploy.
5. Run `kubectl get pods -n spendwise -w` to watch the rolling update to the new SHA.
6. Refresh the browser to see the change. Then open Grafana and point out the request spike.

---

## Repository layout

```
backend/            FastAPI app, Alembic migrations, tests, Dockerfile
frontend/           React app, Nginx config, multi-stage Dockerfile
.github/workflows/  CI/CD pipeline
terraform/          AWS VPC + EKS
k8s/                Namespace manifests
helm/spendwise/     Helm chart for the app
monitoring/         Helm values for Prometheus/Grafana and ingress-nginx, dashboard JSON
scripts/            Cluster bootstrap and teardown helpers
docs/screenshots/   Screenshots for the submission
```
