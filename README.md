# SpendWise: Expense Tracker on a Full DevOps Pipeline

SpendWise is a small personal finance app. You record expenses (title, amount, category, date, notes), filter them by category, and see totals per category on a dashboard. The app itself is simple on purpose. The project is about the delivery pipeline around it: tests, containers, CI/CD with a security gate, AWS infrastructure as code, Kubernetes with Helm, and monitoring.

```
 git push ──► GitHub Actions ──► pytest + ruff ─┐
                                 npm build ─────┼─► docker build ─► Trivy scan ─► push to GHCR (:<sha>)
                                                                                      │
                     kind cluster (CI runner / WSL) ◄── helm upgrade --install ◄──────┘
 Terraform ──► AWS VPC + EKS (optional, paid)   │
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
| CI/CD | GitHub Actions → GHCR (commit-SHA tags) → Helm deploy to kind | [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) |
| Security | Trivy image scan, fails on HIGH/CRITICAL | same workflow |
| Infrastructure | Terraform: VPC + EKS + managed node group | [terraform/](terraform/) |
| Orchestration | Kubernetes (kind) + Helm chart + Ingress | [k8s/](k8s/), [helm/spendwise/](helm/spendwise/) |
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

The app at `http://localhost:3000`, adding an expense and then the updated list with totals:

![SpendWise add-expense form](docs/screenshots/m1-app-add-expense.png)
![SpendWise expense list with category totals](docs/screenshots/m1-app-expense-list.png)

`docker compose up --build`: both images built and the three services created (frontend, backend, postgres):

![docker compose: containers created](docs/screenshots/m4-compose-containers-created.png)

The backend runs the Alembic migration (`create expenses table`), starts Uvicorn, then serves health checks and API calls proxied by the frontend's Nginx:

![Backend migration and requests](docs/screenshots/m1-backend-migration-and-requests.png)

<details>
<summary>Full build and startup log (5 more screenshots)</summary>

![Build log part 1: base images and multi-stage build](docs/screenshots/m4-compose-build-1.png)
![Build log part 2](docs/screenshots/m4-compose-build-2.png)
![Build log part 3: npm build and pip wheels](docs/screenshots/m4-compose-build-3.png)
![Build log part 4: images exported](docs/screenshots/m4-compose-build-4.png)
![Frontend Nginx startup](docs/screenshots/m4-compose-frontend-logs.png)

</details>

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

![pytest -v: 13 passed](docs/screenshots/m2-pytest-passing.png)

---

## 2. CI/CD pipeline

[.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) runs on every push and pull request to `main`:

1. **backend-tests**: `ruff check` followed by `pytest`. A failing test fails the job, and every later job is skipped.
2. **frontend-build**: `npm ci && npm run build`.
3. **images** (matrix: backend, frontend):
   - `docker build`
   - **Trivy** scan with `--severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed`. Any fixable HIGH or CRITICAL CVE fails the pipeline before the image is pushed.
   - Push to `ghcr.io/<owner>/spendwise-<service>:<git-commit-sha>`. Images are never tagged `latest`.
4. **deploy** (push to `main` only), with no cloud account or secrets needed:
   - creates a temporary **kind** Kubernetes cluster on the runner from [k8s/kind-config.yaml](k8s/kind-config.yaml), and installs ingress-nginx
   - `helm upgrade --install` of the chart with `global.imageTag=<sha>`, waiting until every pod is Ready
   - checks that both Deployments run the images for **this commit**
   - smoke-tests through the Ingress: `/` serves the React app, and `/api` creates and lists an expense

The deploy job runs [scripts/local-cluster.sh](scripts/local-cluster.sh), the same script you use to run the cluster locally in WSL. What CI verifies is exactly what you demo.

Trivy runs as a pinned container image (`aquasec/trivy:0.58.1`) instead of through a third-party action. This keeps the scanner version fixed and auditable.

The images must be **Public** under **GitHub → Packages** so a cluster can pull them without credentials. The alternative is to create a pull secret and set `global.imagePullSecrets`.

A green run triggered by a push to `main`: tests and frontend build, then build, scan and push for both images, then the kind deploy ([run 38876693246](https://github.com/Amitabh-Ozymandias/Devops-Final-10104/actions/runs/38876693246)):

![CI/CD run: all five jobs green](docs/screenshots/m5-pipeline-run-green.png)

Both images in GHCR, tagged only with full commit SHAs:

![GHCR spendwise-backend with SHA tags](docs/screenshots/m5-ghcr-backend-sha-tags.png)
![GHCR spendwise-frontend with SHA tags](docs/screenshots/m5-ghcr-frontend-sha-tags.png)

<details>
<summary>Pipeline graph close-up</summary>

![Pipeline graph](docs/screenshots/m5-pipeline-graph.png)

</details>

---

## 3. Security scan (Trivy)

Trivy scans the OS packages (Debian for the backend, Alpine for the frontend) and the language dependencies (Python wheels, npm packages) of each built image. It checks them against public CVE databases. The pipeline only fails on HIGH or CRITICAL issues that have a fix available. Both Dockerfiles run `apt-get upgrade` or `apk upgrade` to pull in OS patches, so a clean scan means no known, fixable, serious vulnerability in either image at build time. If a CVE shows up, the Trivy table names the package, the installed version, and the fixed version. The fix is to bump that dependency or the base image.

**A real finding from this project.** The first scan of the backend image failed with 3 HIGH CVEs in `starlette` 0.41.3, the web framework underneath FastAPI. One was **CVE-2025-62727**: an attacker could send a crafted HTTP `Range` header that makes Starlette merge byte ranges inefficiently, which burns CPU (a denial of service). Trivy reported that version 0.49.1 fixes it. Upgrading to FastAPI 0.143.0 / Starlette 1.7.0 (and `prometheus-fastapi-instrumentator` 8.1.0, which supports Starlette 1.x) brought the scan to `Total: 0 (HIGH: 0, CRITICAL: 0)`.

The Trivy step in the pipeline, scanning `spendwise-backend:<sha>` (Debian 13.7) and passing with `Total: 0 (HIGH: 0, CRITICAL: 0)`:

![Trivy scan result: 0 HIGH, 0 CRITICAL](docs/screenshots/m6-trivy-backend-3-result.png)

<details>
<summary>Earlier part of the Trivy log (DB download, scanners enabled)</summary>

![Trivy step start](docs/screenshots/m6-trivy-backend-1-start.png)
![Trivy scanning](docs/screenshots/m6-trivy-backend-2-scanning.png)

</details>

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

> **Cost warning.** `terraform init`, `validate` and `plan` are free. Only `terraform apply` creates billable resources: the EKS control plane and nodes, about $0.25–0.30 per hour. The app itself never needs EKS, because CI and the local demo both use kind. If you apply for the M7 console screenshots, destroy right after:
> ```bash
> cd terraform && terraform destroy
> ```
> (If you also deployed to EKS with [scripts/bootstrap-cluster.sh](scripts/bootstrap-cluster.sh), use [scripts/teardown.sh](scripts/teardown.sh) instead. It removes the load balancer first.)

**Run on a Free-plan AWS account** (`create_eks = false`, region `ap-southeast-2`, because Free-plan accounts are limited to one region). `terraform plan` created 11 resources: the VPC, 2 public subnets in `ap-southeast-2a`/`2b`, an internet gateway, route tables and the default ACL/security group:

![terraform validate and plan](docs/screenshots/m7-terraform-plan-1-validate.png)
![terraform plan: 11 to add](docs/screenshots/m7-terraform-plan-8-summary.png)

`terraform apply`, followed by `terraform destroy` to leave nothing running:

![terraform apply complete: 11 added](docs/screenshots/m7-terraform-apply-3-complete.png)
![terraform destroy complete: 11 destroyed](docs/screenshots/m7-terraform-destroy-2-complete.png)

<details>
<summary>Full plan, apply and destroy output (9 more screenshots)</summary>

![plan part 2](docs/screenshots/m7-terraform-plan-2.png)
![plan part 3](docs/screenshots/m7-terraform-plan-3.png)
![plan part 4](docs/screenshots/m7-terraform-plan-4.png)
![plan part 5](docs/screenshots/m7-terraform-plan-5.png)
![plan: public subnet in ap-southeast-2a](docs/screenshots/m7-terraform-plan-6-subnet-a.png)
![plan: public subnet in ap-southeast-2b](docs/screenshots/m7-terraform-plan-7-subnet-b.png)
![apply start](docs/screenshots/m7-terraform-apply-1-start.png)
![apply creating resources](docs/screenshots/m7-terraform-apply-2-creating.png)
![destroy start](docs/screenshots/m7-terraform-destroy-1-start.png)

</details>

---

## 5. Kubernetes + Helm

```bash
# One command: kind cluster, namespaces, Prometheus/Grafana, ingress-nginx and the app (free)
./scripts/local-cluster.sh <your-github-user-lowercase> <commit-sha>     # app at http://localhost/

# Same on EKS, if you created it with Terraform (paid)
./scripts/bootstrap-cluster.sh <your-github-user-lowercase> <commit-sha>

# Or step by step on any cluster
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

Deployed on minikube: 2 backend and 2 frontend replicas plus Postgres, all `Running`; ClusterIP Services; the Helm release `deployed`; and the nginx Ingress:

![kubectl get pods/svc, helm list, kubectl get ingress](docs/screenshots/m8-kubectl-pods-svc-helm-ingress.png)

The app served through the Ingress (`kubectl port-forward` to the ingress-nginx controller, port 8080):

![SpendWise via the Ingress](docs/screenshots/m8-app-via-ingress.png)

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

1. Show the app at `http://localhost/` (the local kind cluster) and add a few expenses.
2. Make a visible change, for example the subtitle in [frontend/src/App.jsx](frontend/src/App.jsx).
3. `git commit -am "Update dashboard subtitle" && git push`
4. Watch GitHub Actions run tests, build, Trivy, the GHCR push, and **Deploy to Kubernetes (kind)**, ending with the smoke test passing on the new SHA.
5. Roll the local cluster to the new SHA with `helm upgrade`, and watch `kubectl get pods -n spendwise -w`.
6. Refresh the browser to see the change. Then open Grafana and point out the request spike.

---

## 8. Complete runbook (WSL Ubuntu)

Every command needed to run the whole project and capture every screenshot in `GRADING.md`, in order. Run everything in an **Ubuntu (WSL) terminal** unless a step says otherwise. 📸 marks a screenshot to save in `docs/screenshots/`.

### Step 0: Install the tools (one time)

```bash
sudo apt update
sudo apt install -y git curl unzip gnupg lsb-release python3 python3-venv python3-pip

# Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update

# kubectl
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# Helm 3
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kind (Kubernetes in Docker)
curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.30.0/kind-linux-amd64
sudo install -m 0755 kind /usr/local/bin/kind && rm kind
```

**Docker** (runs natively inside Ubuntu; Docker Desktop is not needed):

```bash
sudo apt install -y docker.io docker-compose-v2 docker-buildx
sudo usermod -aG docker $USER     # then close and reopen the Ubuntu terminal
```

> If `docker compose` says `unknown flag: --build` or `unknown command`, the compose plugin is missing. Run the `apt install` line above.

Check that everything is installed:

```bash
git --version; python3 --version; node --version; docker version --format '{{.Server.Version}}'; docker compose version
terraform version | head -1; aws --version; kubectl version --client | head -1; helm version --short; kind version
```

### Step 1: Open the project in WSL

Work directly in the Windows folder, so WSL and your Windows git always see the same files:

```bash
cd "/mnt/c/Users/USER/Downloads/DEVOPS FINAL PROJECT"
```

> Commit and push from Windows as usual. All the commands below run in WSL from this folder.

### Step 2: Tests and code quality (M2)

```bash
cd "/mnt/c/Users/USER/Downloads/DEVOPS FINAL PROJECT/backend"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
ruff check .
pytest -v                      # 📸 all 13 tests PASSED
deactivate
```

### Step 3: Run the stack with Docker Compose (M1, M4)

```bash
cd "/mnt/c/Users/USER/Downloads/DEVOPS FINAL PROJECT"
docker compose up --build      # 📸 terminal showing the three services starting
```

Leave it running. Open a **second** WSL terminal:

```bash
curl -s localhost:8000/health
curl -s -X POST localhost:8000/api/expenses -H 'Content-Type: application/json' \
  -d '{"title":"Groceries","amount":42.5,"category":"Food","spent_on":"2026-10-16"}'
curl -s localhost:8000/api/expenses
curl -s localhost:8000/metrics | grep http_requests_total     # 📸 /metrics output
docker compose exec backend id                                # uid=10001(app), so non-root
docker compose exec frontend id                               # uid=101(nginx), so non-root
```

In a Windows browser, open **http://localhost:3000**. Add, edit and delete a few expenses, and use the category filter. 📸 the app in the browser.

Stop the stack with `Ctrl+C` in the first terminal, then run:

```bash
docker compose down            # add -v to also delete the local database
```

### Step 4: Git and GitHub (M3)

```bash
git log --oneline | head -20   # 📸 15+ commits with meaningful messages
```

Also screenshot `https://github.com/Amitabh-Ozymandias/Devops-Final-10104/commits/main`.

### Step 5: CI/CD and Trivy (M5, M6)

The pipeline runs on every push to `main`. Open **GitHub → Actions → CI/CD → the latest run**:

- 📸 the run summary with all jobs green
- 📸 open **Build, scan & push (backend)** → expand **Trivy scan**, and capture `Total: 0 (HIGH: 0, CRITICAL: 0)`

Make sure the images are pullable by a cluster (already done for this repo). Go to **GitHub → your profile → Packages**, open `spendwise-backend` → **Package settings** → **Change visibility → Public**, and do the same for `spendwise-frontend`. 📸 a package page showing the commit-SHA tag.

Trivy explanation for the submission: see [section 3](#3-security-scan-trivy).

### Step 6: Kubernetes + Helm on a local kind cluster (M8), free

Use the SHA of the latest commit whose pipeline is green. Images are tagged with it.

```bash
cd "/mnt/c/Users/USER/Downloads/DEVOPS FINAL PROJECT"
export TAG=$(git rev-parse HEAD)

# kind cluster + namespaces + Prometheus/Grafana + ingress-nginx + the app (~10 minutes the first time)
bash scripts/local-cluster.sh amitabh-ozymandias "$TAG"
```

> Port 80 must be free. Stop the compose stack first (`docker compose down`) if it's still running.

Collect the M8 evidence:

```bash
kubectl apply -f k8s/namespace.yaml          # shows "unchanged", so it applies cleanly
kubectl get pods -n spendwise                # 📸 2 backend + 2 frontend + postgres, all Running
kubectl get svc -n spendwise                 # 📸 ClusterIP services
helm list -n spendwise                       # 📸 the spendwise release, deployed
kubectl get ingress -n spendwise             # 📸 class nginx, address localhost
curl -s localhost/api/expenses/summary       # /api is routed to the backend
```

In a Windows browser, open **http://localhost/** (served through the Ingress, not compose). 📸 the app.

### Step 7: Observability (M9)

```bash
# /metrics from the backend inside the cluster
kubectl port-forward -n spendwise svc/spendwise-backend 8000:8000 &
sleep 2; curl -s localhost:8000/metrics | head -40    # 📸
kill %1

# Generate traffic so the dashboards have data
for i in $(seq 1 300); do
  curl -s localhost/api/expenses > /dev/null
  curl -s -X POST localhost/api/expenses -H 'Content-Type: application/json' \
    -d "{\"title\":\"Load test $i\",\"amount\":$((RANDOM % 90 + 10)),\"category\":\"Food\",\"spent_on\":\"2026-10-16\"}" > /dev/null
  curl -s localhost/api/expenses/999999 > /dev/null   # produces 404s for the status panel
done

# Prometheus: http://localhost:9090/targets
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# 📸 the "serviceMonitor/spendwise/spendwise-backend/0" target with 2/2 UP. Press Ctrl+C when done.

# Grafana: http://localhost:3001  (user admin, password printed below)
kubectl get secret -n monitoring monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl port-forward -n monitoring svc/monitoring-grafana 3001:80
# Dashboards → "SpendWise - API Overview". 📸 the populated panels
```

### Step 8: Terraform for AWS (M7)

EKS is switchable with `create_eks` in `terraform.tfvars`. Running the app never needs it, because CI and the demo use kind/minikube.

**A. Free: VPC only (`create_eks = false`, the default).** Creates a real VPC with 2 public subnets, an internet gateway and route tables. All of these are free, and they work on AWS **Free-plan** accounts, which block EKS.

```bash
cd "/mnt/c/Users/USER/Downloads/DEVOPS FINAL PROJECT/terraform"
cp terraform.tfvars.example terraform.tfvars   # create_eks = false
terraform init
terraform fmt -check && terraform validate
terraform plan                 # 📸 ends with "Plan: N to add, 0 to change, 0 to destroy"
terraform apply                # type "yes"; about 1 minute
terraform output
```

- 📸 AWS Console, region **N. Virginia (us-east-1)**: **VPC → Your VPCs** (`spendwise-vpc`) and **VPC → Subnets** (the 2 `spendwise-vpc-public-…` subnets).

```bash
terraform destroy              # type "yes". 📸 "Destroy complete! Resources: N destroyed."
aws ec2 describe-vpcs --region us-east-1 --filters Name=tag:Project,Values=spendwise --query 'Vpcs[].VpcId'   # []
```

**B. With EKS (`create_eks = true`).** This needs a Paid-plan account; credits still apply. It costs about $0.25–0.30 per hour, so plan on ~40 minutes and under $0.50 in total.

```bash
# Use a Kubernetes version in standard support (extended support costs ~6x more)
aws eks describe-cluster-versions --region us-east-1 \
  --query "clusterVersions[?versionStatus=='STANDARD_SUPPORT'].clusterVersion" --output text
nano terraform.tfvars          # create_eks = true, kubernetes_version = newest listed above

terraform apply                # type "yes"; takes ~15 minutes
```

- 📸 additionally **EKS → Clusters → spendwise-eks**, Active, with the node group on the **Compute** tab. Then run `terraform destroy` exactly as in option A.

### Step 9: Live demo (M10)

1. Have `http://localhost/` open, served by the kind cluster from Step 6.
2. In **Windows**, change something visible. For example, edit the subtitle text `Track where your money goes.` in `frontend/src/App.jsx`.
3. Commit and push from Windows: `git commit -am "Change dashboard subtitle for live demo"` then `git push`.
4. In **GitHub → Actions**, follow the run: tests → frontend build → image build → Trivy → GHCR push → **Deploy to Kubernetes (kind)**. That job deploys the new SHA with Helm and smoke-tests it through the Ingress.
5. When it's green, roll your local cluster to the same commit and watch the rolling update (in WSL):
   ```bash
   helm upgrade spendwise helm/spendwise -n spendwise --reuse-values --set global.imageTag=$(git rev-parse HEAD)
   kubectl get pods -n spendwise -w           # old pods terminate, new ones start. Ctrl+C when settled
   kubectl get deploy -n spendwise -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
   ```
6. Refresh `http://localhost/` to see the new subtitle. Then show Grafana.

### Step 10: Save the screenshots

From Windows, copy your screenshots into `docs/screenshots/`. Then commit and push:

```
git add docs/screenshots
git commit -m "Add submission screenshots"
git push
```

### Step 11: Clean up

```bash
kind delete cluster --name spendwise        # removes the local cluster and frees disk space
docker compose down -v                      # if the compose stack is still around
# If you ran Step 8 B, confirm that `terraform destroy` finished (see above)
```

### Screenshot checklist

| Module | Screenshot | Step |
|---|---|---|
| M1/M4 | App in the browser at `localhost:3000` | 3 |
| M4 | `docker compose up --build` output | 3 |
| M2 | `pytest -v`, all passing | 2 |
| M3 | Commit history (10+ commits) | 4 |
| M5 | Green Actions run (including Deploy to Kubernetes), plus the GHCR package with its SHA tag | 5 |
| M6 | Trivy step output | 5 |
| M7 | `terraform plan`, VPC + subnets in the console, `terraform destroy` (EKS too with option B) | 8 |
| M8 | `kubectl get pods`, `kubectl get svc`, `helm list`, app via the Ingress at `http://localhost/` | 6 |
| M9 | `/metrics`, Prometheus target UP, Grafana dashboard | 7 |
| M10 | Live demo (or a recording of Step 9) | 9 |

---

## Repository layout

```
backend/            FastAPI app, Alembic migrations, tests, Dockerfile
frontend/           React app, Nginx config, multi-stage Dockerfile
.github/workflows/  CI/CD pipeline
terraform/          AWS VPC + EKS (optional, paid)
k8s/                Namespace manifests, kind cluster config
helm/spendwise/     Helm chart for the app
monitoring/         Helm values for Prometheus/Grafana and ingress-nginx, dashboard JSON
scripts/            local-cluster.sh (kind, used by CI), EKS bootstrap/teardown
docs/screenshots/   Screenshots for the submission
```
