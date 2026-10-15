#!/usr/bin/env bash
# Prepare each worker over SSH and join it to the cluster.
# Run on k8-control as vaviles (not root): ./join-workers.sh
# Safe to re-run: a worker that has already joined is only re-prepared.
set -euo pipefail

WORKERS=(k8-worker-1 k8-worker-2)
SSH_USER=vaviles
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -ne 0 ] || { echo "Run as $SSH_USER, not root (it uses your SSH key)." >&2; exit 1; }
kubectl get node k8-control >/dev/null || { echo "Run control-plane-init.sh first." >&2; exit 1; }

for w in "${WORKERS[@]}"; do
  echo "=== $w"
  # First connection records the worker's host key; check it on the Proxmox console if in doubt
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$w" true
  ssh "$SSH_USER@$w" "sudo bash -s" < "$HERE/node-prep.sh"

  if kubectl get node "$w" >/dev/null 2>&1; then
    echo "$w is already in the cluster"
    continue
  fi
  # Short-lived token, used once
  join=$(sudo kubeadm token create --ttl 30m --print-join-command)
  ssh "$SSH_USER@$w" "sudo $join"
done

echo "Waiting for all nodes to be Ready..."
for w in "${WORKERS[@]}"; do
  until kubectl get node "$w" >/dev/null 2>&1; do sleep 5; done
  kubectl wait --for=condition=Ready "node/$w" --timeout=600s
  kubectl label node "$w" node-role.kubernetes.io/worker= --overwrite
done
kubectl get nodes -o wide
