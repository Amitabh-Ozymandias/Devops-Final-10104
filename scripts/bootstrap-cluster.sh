#!/usr/bin/env bash
# Installs everything the app needs on a fresh EKS cluster, then the app itself.
# Usage: ./scripts/bootstrap-cluster.sh <ghcr-owner> <image-tag>
#   e.g. ./scripts/bootstrap-cluster.sh my-github-user 3f2c1e9...
set -euo pipefail

OWNER="${1:?GitHub owner (lowercase) required}"
TAG="${2:?image tag (git commit SHA) required}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER_NAME:-spendwise-eks}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo ">> Pointing kubectl at $CLUSTER ($REGION)"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo ">> Namespaces"
kubectl apply -f "$ROOT/k8s/namespace.yaml"

echo ">> Helm repositories"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

# Monitoring first so its CRDs (ServiceMonitor) exist before the other charts
echo ">> Prometheus + Grafana"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f "$ROOT/monitoring/kube-prometheus-stack-values.yaml" \
  --wait --timeout 15m

echo ">> ingress-nginx"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f "$ROOT/monitoring/ingress-nginx-values.yaml" \
  --wait --timeout 10m

echo ">> SpendWise"
helm upgrade --install spendwise "$ROOT/helm/spendwise" \
  --namespace spendwise \
  --set global.imageRegistry="ghcr.io/$OWNER" \
  --set global.imageTag="$TAG" \
  ${POSTGRES_PASSWORD:+--set postgresql.auth.password="$POSTGRES_PASSWORD"} \
  --wait --timeout 10m

kubectl get pods -n spendwise
echo
echo "App URL: http://$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/"
echo "Grafana: kubectl port-forward -n monitoring svc/monitoring-grafana 3001:80  ->  http://localhost:3001"
echo "Prometheus: kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
