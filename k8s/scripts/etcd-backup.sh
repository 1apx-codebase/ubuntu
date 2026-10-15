#!/usr/bin/env bash
# Back up the cluster state: an etcd snapshot plus the control plane's certificates and config.
# Run on k8-control as root: sudo ./etcd-backup.sh
# Schedule it daily, e.g. /etc/cron.d/etcd-backup:
#   30 2 * * * root /home/vaviles/codebase/github/ubuntu/k8s/scripts/etcd-backup.sh
set -euo pipefail

BACKUP_DIR=/var/backups/kubernetes
KEEP_DAYS=14

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf
stamp=$(date +%F-%H%M%S)
install -d -m 0700 "$BACKUP_DIR"

# etcdctl runs inside the etcd pod, which has the client certificates mounted
pod=$(kubectl get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system "$pod" -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/backup.db
mv /var/lib/etcd/backup.db "$BACKUP_DIR/etcd-$stamp.db"

# Certificates, kubeconfigs and static pod manifests are needed to restore the snapshot
tar -czf "$BACKUP_DIR/kubernetes-etc-$stamp.tgz" -C / etc/kubernetes
chmod 600 "$BACKUP_DIR"/*"$stamp"*

find "$BACKUP_DIR" -type f -mtime +"$KEEP_DAYS" -delete
ls -lh "$BACKUP_DIR" | tail -4
echo "Copy $BACKUP_DIR off this VM (it holds the cluster's private keys)."
