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
  rssh "$w" true </dev/null
  # Let first-boot cloud-init (including its package upgrade) finish, so apt isn't locked
  rssh "$w" "sudo cloud-init status --wait >/dev/null 2>&1 || true" </dev/null
  # Copy node-prep.sh over and run it from a file, so nothing it runs can read the
  # rest of the script from stdin
  tmp=$(rssh "$w" mktemp </dev/null)
  rssh "$w" "cat > $tmp" < "$HERE/node-prep.sh"
  rssh "$w" "sudo bash $tmp; rc=\$?; rm -f $tmp; exit \$rc" </dev/null

  if kubectl get node "$w" >/dev/null 2>&1; then
    echo "$w is already in the cluster"
    continue
  fi
  # Short-lived token, deleted once the worker has joined (it expires after 30 minutes
  # anyway, if the join fails)
  join=$(kubeadm token create --ttl 30m --print-join-command)
  token=$(awk '{for (i = 1; i < NF; i++) if ($i == "--token") print $(i + 1)}' <<<"$join")
  rssh "$w" "sudo $join" </dev/null
  kubeadm token delete "$token" >/dev/null
done

echo "Waiting for all nodes to be Ready..."
for w in "${WORKERS[@]}"; do
  for i in $(seq 1 60); do   # up to 5 minutes to register after joining
    kubectl get node "$w" >/dev/null 2>&1 && break
    [ "$i" -lt 60 ] || { echo "$w didn't register; on it: sudo journalctl -u kubelet -n 50" >&2; exit 1; }
    sleep 5
  done
  kubectl wait --for=condition=Ready "node/$w" --timeout=600s
  kubectl label node "$w" node-role.kubernetes.io/worker= --overwrite
done
kubectl get nodes -o wide
