#!/usr/bin/env bash
# Install the cluster add-ons ORDS needs: MetalLB (LAN IPs for services)
# and metrics-server (kubectl top, autoscaling).
# Run on k8-control as vaviles after join-workers.sh: ./cluster-addons.sh
# Safe to re-run.
set -euo pipefail

METALLB_VERSION=v0.16.0
METRICS_SERVER_VERSION=v0.9.0
K8S=$(cd "$(dirname "$0")/.." && pwd)   # the k8s/ folder
# shellcheck source=common.sh
. "$K8S/scripts/common.sh"

[ "$(id -u)" -ne 0 ] || { echo "Run as vaviles, not root." >&2; exit 1; }
retry() { for _ in $(seq 1 30); do "$@" && return 0; sleep 10; done; return 1; }
dl=$(mktemp -d)
trap 'rm -rf "$dl"' EXIT

# 1. MetalLB in layer-2 mode, with the LAN address pool in manifests/addons/metallb-pool.yaml.
#    Upstream files are checked against their pinned SHA-256 (config/upstream.sha256).
fetch_verified "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml" "$dl/metallb.yaml"
kubectl apply -f "$dl/metallb.yaml"
kubectl rollout status deployment/controller -n metallb-system --timeout=300s
kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s
# The webhook can take a moment after rollout, so retry the pool
retry kubectl apply -f "$K8S/manifests/addons/metallb-pool.yaml"

# 2. metrics-server. kubelets use self-signed serving certificates, so skip verifying them.
#    The flag goes into the file before applying, so a re-run changes nothing.
fetch_verified "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml" "$dl/metrics-server.yaml"
sed -i 's|^\( *\)- --metric-resolution=15s$|&\n\1- --kubelet-insecure-tls|' "$dl/metrics-server.yaml"
grep -q -- '- --kubelet-insecure-tls$' "$dl/metrics-server.yaml" \
  || { echo "Could not add --kubelet-insecure-tls to metrics-server." >&2; exit 1; }
kubectl apply -f "$dl/metrics-server.yaml"
kubectl rollout status deployment/metrics-server -n kube-system --timeout=300s

kubectl get ipaddresspools -n metallb-system
retry kubectl top nodes
