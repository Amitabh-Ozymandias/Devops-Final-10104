#!/usr/bin/env bash
# Removes the load balancer created by ingress-nginx BEFORE `terraform destroy`.
# An NLB left behind keeps network interfaces in the VPC and makes the destroy hang.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

helm uninstall spendwise -n spendwise || true
helm uninstall ingress-nginx -n ingress-nginx || true
helm uninstall monitoring -n monitoring || true

echo ">> Waiting 60s for AWS to delete the load balancer..."
sleep 60

cd "$ROOT/terraform"
terraform destroy -auto-approve
