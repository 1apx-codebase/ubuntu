#!/usr/bin/env bash
# Prepare each worker over SSH and join it to the cluster.
# Run on k8-control as root: sudo ./join-workers.sh
# It logs in to the workers as k8sadmin, with k8sadmin's key.
# Safe to re-run: a worker that has already joined is only re-prepared.
set -euo pipefail

WORKERS=(k8-worker-1 k8-worker-2)
SSH_USER=k8sadmin
SSH_KEY=/home/$SSH_USER/.ssh/id_ed25519
export KUBECONFIG=/etc/kubernetes/admin.conf
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ -f "$SSH_KEY" ] || { echo "Run create-admin-user.sh first." >&2; exit 1; }
# First connection to a worker records its host key; check it on the Proxmox console if in doubt
rssh() { ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$SSH_USER@$1" "${@:2}"; }
kubectl get node k8-control >/dev/null || { echo "Run control-plane-init.sh first." >&2; exit 1; }

for w in "${WORKERS[@]}"; do
  echo "=== $w"
  rssh "$w" true
  rssh "$w" "sudo bash -s" < "$HERE/node-prep.sh"

  if kubectl get node "$w" >/dev/null 2>&1; then
    echo "$w is already in the cluster"
    continue
  fi
  # Short-lived token, used once
  join=$(kubeadm token create --ttl 30m --print-join-command)
  rssh "$w" "sudo $join"
done

echo "Waiting for all nodes to be Ready..."
for w in "${WORKERS[@]}"; do
  until kubectl get node "$w" >/dev/null 2>&1; do sleep 5; done
  kubectl wait --for=condition=Ready "node/$w" --timeout=600s
  kubectl label node "$w" node-role.kubernetes.io/worker= --overwrite
done
kubectl get nodes -o wide
