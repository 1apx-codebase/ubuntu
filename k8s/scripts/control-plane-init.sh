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
ENC_DIR=/etc/kubernetes/enc       # must match the encryption-provider-config path in $CONFIG
# shellcheck source=common.sh
. "$K8S/scripts/common.sh"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ "$(hostname -s)" = k8-control ] || { echo "Run this on k8-control." >&2; exit 1; }
grep -q "podSubnet: $POD_CIDR" "$CONFIG" || { echo "POD_CIDR doesn't match $CONFIG." >&2; exit 1; }

# 1. Control plane
if [ ! -f /etc/kubernetes/admin.conf ]; then
  # Encrypt Secrets (database passwords, the TLS key) in etcd, and so in etcd backups.
  # The key is made here and kept only on this node (etcd-backup.sh saves it), never in git.
  if [ ! -f "$ENC_DIR/encryption-config.yaml" ]; then
    key=$(head -c 32 /dev/urandom | base64)
    [ "${#key}" -eq 44 ] || { echo "Could not generate the encryption key." >&2; exit 1; }
    install -d -m 0700 "$ENC_DIR"
    # Written to a temporary name and renamed, so a failure never leaves a broken file
    ( umask 077
      cat > "$ENC_DIR/encryption-config.yaml.new" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets]
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: $key
      - identity: {}
EOF
    )
    mv "$ENC_DIR/encryption-config.yaml.new" "$ENC_DIR/encryption-config.yaml"
    unset key
  fi
  install -D -m 0600 "$K8S/manifests/audit-policy.yaml" /etc/kubernetes/audit/policy.yaml
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
#    Since Calico 3.30 the operator's CRDs are in their own file, installed first.
#    "create", not "apply": the CRDs are too large for apply's last-applied annotation.
#    Every file is checked against its pinned SHA-256 (config/upstream.sha256).
dl=$(mktemp -d)
trap 'rm -rf "$dl"' EXIT
calico="https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests"
for f in operator-crds.yaml tigera-operator.yaml custom-resources.yaml; do
  fetch_verified "$calico/$f" "$dl/$f"
done
if ! kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; then
  kubectl create -f "$dl/operator-crds.yaml"
fi
if ! kubectl get namespace tigera-operator >/dev/null 2>&1; then
  kubectl create -f "$dl/tigera-operator.yaml"
fi
kubectl wait --for condition=established --timeout=180s crd/installations.operator.tigera.io
sed -i "s|cidr: 192.168.0.0/16|cidr: $POD_CIDR|" "$dl/custom-resources.yaml"
grep -q "cidr: $POD_CIDR" "$dl/custom-resources.yaml" || { echo "Could not set the Calico pod CIDR." >&2; exit 1; }
kubectl apply -f "$dl/custom-resources.yaml"

# 4. Wait for the network and the node
echo "Waiting for Calico to start (a few minutes)..."
for i in $(seq 1 120); do   # up to 10 minutes for the operator to create it
  kubectl get daemonset calico-node -n calico-system >/dev/null 2>&1 && break
  [ "$i" -lt 120 ] || { echo "Calico didn't start; see: kubectl get pods -n tigera-operator" >&2; exit 1; }
  sleep 5
done
kubectl rollout status daemonset/calico-node -n calico-system --timeout=600s
kubectl wait --for=condition=Ready node/k8-control --timeout=300s
kubectl get nodes -o wide
kubectl get pods -A
echo "Control plane is ready. Next: sudo ./join-workers.sh"
