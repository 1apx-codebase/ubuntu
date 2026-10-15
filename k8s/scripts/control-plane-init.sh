#!/usr/bin/env bash
# Create the cluster's control plane on k8-control and install the Calico pod network.
# Run on k8-control as root after node-prep.sh: sudo ./control-plane-init.sh
# Safe to re-run: kubeadm init is skipped if the cluster already exists.
set -euo pipefail

CALICO_VERSION=v3.32.2
POD_CIDR=10.244.0.0/16            # must match podSubnet in kubeadm-config.yaml
KUBECONFIG_USERS="vaviles k8sadmin"   # each gets the admin kubeconfig in ~/.kube/config
K8S=$(cd "$(dirname "$0")/.." && pwd)   # the k8s/ folder
CONFIG="$K8S/manifests/kubeadm-config.yaml"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ "$(hostname -s)" = k8-control ] || { echo "Run this on k8-control." >&2; exit 1; }
grep -q "podSubnet: $POD_CIDR" "$CONFIG" || { echo "POD_CIDR doesn't match $CONFIG." >&2; exit 1; }

# 1. Control plane
if [ ! -f /etc/kubernetes/admin.conf ]; then
  kubeadm config validate --config "$CONFIG"
  kubeadm config images pull --config "$CONFIG"
  kubeadm init --config "$CONFIG"
else
  echo "Control plane already initialized, skipping kubeadm init"
fi

# 2. kubectl access for the admin users
for u in $KUBECONFIG_USERS; do
  id "$u" >/dev/null 2>&1 || { echo "User $u doesn't exist, skipping its kubeconfig"; continue; }
  home=$(getent passwd "$u" | cut -d: -f6)
  install -d -o "$u" -g "$u" -m 0700 "$home/.kube"
  install -o "$u" -g "$u" -m 0600 /etc/kubernetes/admin.conf "$home/.kube/config"
done
export KUBECONFIG=/etc/kubernetes/admin.conf

# 3. Calico pod network, using our pod CIDR instead of Calico's 192.168.0.0/16 default (overlaps the LAN)
if ! kubectl get namespace tigera-operator >/dev/null 2>&1; then
  kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml"
fi
kubectl wait --for condition=established --timeout=180s crd/installations.operator.tigera.io
cr=$(mktemp)
trap 'rm -f "$cr"' EXIT
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/custom-resources.yaml" \
  | sed "s|cidr: 192.168.0.0/16|cidr: $POD_CIDR|" > "$cr"
grep -q "cidr: $POD_CIDR" "$cr" || { echo "Could not set the Calico pod CIDR." >&2; exit 1; }
kubectl apply -f "$cr"

# 4. Wait for the network and the node
echo "Waiting for Calico to start (a few minutes)..."
until kubectl get daemonset calico-node -n calico-system >/dev/null 2>&1; do sleep 5; done
kubectl rollout status daemonset/calico-node -n calico-system --timeout=600s
kubectl wait --for=condition=Ready node/k8-control --timeout=300s
kubectl get nodes -o wide
kubectl get pods -A
echo "Control plane is ready. Next: sudo ./join-workers.sh"
