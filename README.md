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
terraform version | head -1; aws --version; kubectl version --client | head -1; helm version --short
```

### Step 1: Get the code into WSL

```bash
cd ~
git clone https://github.com/Amitabh-Ozymandias/Devops-Final-10104.git
cd Devops-Final-10104
```

> Commit and push from Windows as usual. Before running anything in WSL, run `git pull` in `~/Devops-Final-10104` to pick up your latest changes.

### Step 2: Tests and code quality (M2)

```bash
cd ~/Devops-Final-10104/backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
ruff check .
pytest -v                      # 📸 all 13 tests PASSED
deactivate
```

### Step 3: Run the stack with Docker Compose (M1, M4)

```bash
cd ~/Devops-Final-10104
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

Then make the images pullable by the cluster. Go to **GitHub → your profile → Packages**, open `spendwise-backend` → **Package settings** → **Change visibility → Public**, and do the same for `spendwise-frontend`. 📸 a package page showing the commit-SHA tag.

Trivy explanation for the submission: see [section 3](#3-security-scan-trivy).

### Step 6: Provision AWS with Terraform (M7)

> 💸 EKS costs roughly $0.25–0.30 per hour while it exists. Do Steps 6 to 10 in one sitting and always finish with Step 11.

Use an **IAM user** (not the root account) with admin permissions. Create its access key in **AWS Console → IAM → Users → Security credentials**.

```bash
aws configure                  # paste the access key and secret, region us-east-1, output json
aws sts get-caller-identity    # confirms which identity you're using

cd ~/Devops-Final-10104/terraform
cp terraform.tfvars.example terraform.tfvars

# Pick a Kubernetes version in standard support (extended support costs ~6x more)
aws eks describe-cluster-versions --region us-east-1 \
  --query "clusterVersions[?versionStatus=='STANDARD_SUPPORT'].clusterVersion" --output text
nano terraform.tfvars          # set kubernetes_version to the newest version listed above

terraform init
terraform fmt -check && terraform validate
terraform plan -out=tfplan     # 📸 the plan, ending with "Plan: N to add, 0 to change, 0 to destroy"
terraform apply tfplan         # takes about 15 minutes
terraform output
```

In the AWS Console (region **N. Virginia, us-east-1**):

- 📸 **VPC → Your VPCs** showing `spendwise-vpc`, and **Subnets** showing its 2 public subnets
- 📸 **EKS → Clusters → spendwise-eks**, Active, with the node group on the **Compute** tab

### Step 7: Deploy to Kubernetes with Helm (M8, M9)

Use the SHA of the latest commit whose pipeline is green. Images are tagged with it.

```bash
cd ~/Devops-Final-10104
git pull
export TAG=$(git rev-parse HEAD)
export POSTGRES_PASSWORD='choose-a-strong-password'   # letters, digits and dashes only; same value as the GitHub secret in Step 8

aws eks update-kubeconfig --region us-east-1 --name spendwise-eks
kubectl get nodes              # 2 nodes Ready

# Installs the namespaces, Prometheus + Grafana, ingress-nginx and the app (~10 minutes)
bash scripts/bootstrap-cluster.sh amitabh-ozymandias "$TAG"
```

Collect the M8 evidence:

```bash
kubectl apply -f k8s/namespace.yaml          # shows "unchanged", so it applies cleanly
kubectl get pods -n spendwise                # 📸 2 backend + 2 frontend + postgres, all Running
kubectl get svc -n spendwise                 # 📸 ClusterIP services
helm list -n spendwise                       # 📸 the spendwise release, deployed
kubectl get ingress -n spendwise             # the ADDRESS column shows the load balancer hostname

export APP_URL=http://$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $APP_URL                                # open it in a browser (allow 2-3 min for DNS). 📸 the app
curl -s $APP_URL/api/expenses/summary        # /api is routed to the backend
```

Collect the M9 evidence:

```bash
# /metrics from the backend inside the cluster
kubectl port-forward -n spendwise svc/spendwise-backend 8000:8000 &
curl -s localhost:8000/metrics | head -40    # 📸
kill %1

# Generate traffic so the dashboards have data
for i in $(seq 1 300); do
  curl -s $APP_URL/api/expenses > /dev/null
  curl -s -X POST $APP_URL/api/expenses -H 'Content-Type: application/json' \
    -d "{\"title\":\"Load test $i\",\"amount\":$((RANDOM % 90 + 10)),\"category\":\"Food\",\"spent_on\":\"2026-10-16\"}" > /dev/null
  curl -s $APP_URL/api/expenses/999999 > /dev/null   # produces 404s for the status panel
done

# Prometheus: http://localhost:9090/targets
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# 📸 the "serviceMonitor/spendwise/spendwise-backend/0" target with 2/2 UP. Press Ctrl+C when done.

# Grafana: http://localhost:3001  (user admin)
kubectl get secret -n monitoring monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl port-forward -n monitoring svc/monitoring-grafana 3001:80
# Dashboards → "SpendWise - API Overview". 📸 the populated panels
```

### Step 8: Turn on automatic deploys (M5, M10)

In **GitHub → repo → Settings → Secrets and variables → Actions**:

| Tab | Name | Value |
|---|---|---|
| Secrets | `AWS_ACCESS_KEY_ID` | same IAM user as `aws configure` |
| Secrets | `AWS_SECRET_ACCESS_KEY` | same IAM user |
| Secrets | `POSTGRES_PASSWORD` | the same value you exported in Step 7 |
| Variables | `DEPLOY_ENABLED` | `true` |
| Variables | `AWS_REGION` | `us-east-1` |
| Variables | `EKS_CLUSTER_NAME` | `spendwise-eks` |

Using the same IAM user that ran Terraform means it already has cluster admin access, so `ci_deployer_arn` can stay empty.

### Step 9: Live demo (M10)

1. In **Windows**, change something visible. For example, edit the subtitle text `Track where your money goes.` in `frontend/src/App.jsx`.
2. Commit and push from Windows: `git commit -am "Change dashboard subtitle for live demo"` then `git push`.
3. In WSL, watch the pods roll over to the new image:
   ```bash
   kubectl get pods -n spendwise -w
   ```
4. In the browser, follow the run in **GitHub → Actions**: tests → build → Trivy → push → **Deploy to EKS**.
5. Refresh `$APP_URL` to see the new subtitle, and confirm the image tag changed:
   ```bash
   kubectl get deploy -n spendwise -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
   ```

### Step 10: Save the screenshots

From Windows, copy your screenshots into `docs/screenshots/`. Then commit and push:

```
git add docs/screenshots
git commit -m "Add submission screenshots"
git push
```

### Step 11: Tear everything down (M7)

```bash
cd ~/Devops-Final-10104
bash scripts/teardown.sh       # uninstalls Helm releases (deletes the load balancer), then terraform destroy
# 📸 "Destroy complete! Resources: N destroyed."

# Confirm nothing billable is left
aws eks list-clusters --region us-east-1                       # []
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName'   # []
aws ec2 describe-vpcs --region us-east-1 --filters Name=tag:Project,Values=spendwise --query 'Vpcs[].VpcId'   # []
```

Also set the `DEPLOY_ENABLED` variable back to `false`, so later pushes don't try to deploy to a cluster that no longer exists.

### Screenshot checklist

| Module | Screenshot | Step |
|---|---|---|
| M1/M4 | App in the browser at `localhost:3000` | 3 |
| M4 | `docker compose up --build` output | 3 |
| M2 | `pytest -v`, all passing | 2 |
| M3 | Commit history (10+ commits) | 4 |
| M5 | Green Actions run, plus the GHCR package with its SHA tag | 5 |
| M6 | Trivy step output | 5 |
| M7 | `terraform plan`, VPC + EKS in the console, `terraform destroy` | 6, 11 |
| M8 | `kubectl get pods`, `kubectl get svc`, `helm list`, app via the Ingress | 7 |
| M9 | `/metrics`, Prometheus target UP, Grafana dashboard | 7 |
| M10 | Live demo (or a recording of Step 9) | 9 |

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
