#!/usr/bin/env bash
# Install the cluster add-ons ORDS needs: MetalLB (LAN IPs for services)
# and metrics-server (kubectl top, autoscaling).
# Run on k8-control as vaviles after join-workers.sh: ./cluster-addons.sh
# Safe to re-run.
set -euo pipefail

METALLB_VERSION=v0.16.0
LB_RANGE=192.168.1.180-192.168.1.189   # reserve this range on the router (outside DHCP)
METRICS_SERVER_VERSION=v0.9.0

retry() { for i in $(seq 1 30); do "$@" && return 0; sleep 10; done; return 1; }

# 1. MetalLB in layer-2 mode
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"
kubectl rollout status deployment/controller -n metallb-system --timeout=300s
kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s
# The webhook can take a moment after rollout, so retry the pool
pool=$(mktemp)
trap 'rm -f "$pool"' EXIT
cat > "$pool" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - $LB_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lan-pool
EOF
retry kubectl apply -f "$pool"

# 2. metrics-server. kubelets use self-signed serving certificates, so skip verifying them
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml"
if ! kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  kubectl patch deployment metrics-server -n kube-system --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl rollout status deployment/metrics-server -n kube-system --timeout=300s

kubectl get ipaddresspools -n metallb-system
retry kubectl top nodes
