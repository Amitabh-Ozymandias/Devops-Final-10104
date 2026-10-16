#!/usr/bin/env bash
# Creates a local kind cluster and installs ingress-nginx, Prometheus + Grafana
# and SpendWise into it. Free alternative to EKS for the Kubernetes/Helm and
# observability steps. Used by the CI deploy job too (with SKIP_MONITORING=1).
#
# Usage: ./scripts/local-cluster.sh <ghcr-owner> <image-tag>
#   e.g. ./scripts/local-cluster.sh amitabh-ozymandias "$(git rev-parse HEAD)"
set -euo pipefail

OWNER="${1:?GitHub owner (lowercase) required}"
TAG="${2:?image tag (git commit SHA) required}"
CLUSTER="${CLUSTER_NAME:-spendwise}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.12.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo ">> Creating kind cluster '$CLUSTER'"
  kind create cluster --name "$CLUSTER" --config "$ROOT/k8s/kind-config.yaml" --wait 180s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo ">> Namespaces"
kubectl apply -f "$ROOT/k8s/namespace.yaml"

if [ "${SKIP_MONITORING:-0}" != "1" ]; then
  echo ">> Prometheus + Grafana (kube-prometheus-stack)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    -f "$ROOT/monitoring/kube-prometheus-stack-values.yaml" \
    --wait --timeout 15m
fi

echo ">> ingress-nginx ($INGRESS_NGINX_VERSION, kind provider)"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX_VERSION/deploy/static/provider/kind/deploy.yaml"
kubectl wait -n ingress-nginx --for=condition=complete job --all --timeout=180s
kubectl wait -n ingress-nginx --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s

echo ">> SpendWise $TAG"
helm upgrade --install spendwise "$ROOT/helm/spendwise" \
  --namespace spendwise \
  --set global.imageRegistry="ghcr.io/$OWNER" \
  --set global.imageTag="$TAG" \
  ${POSTGRES_PASSWORD:+--set postgresql.auth.password="$POSTGRES_PASSWORD"} \
  --wait --timeout 10m

kubectl get pods -n spendwise
echo
echo "App:        http://localhost/"
echo "Prometheus: kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
echo "Grafana:    kubectl port-forward -n monitoring svc/monitoring-grafana 3001:80"
