#!/usr/bin/env bash
# Back up the cluster state: an etcd snapshot plus the control plane's certificates and config.
# Run on k8-control as root: sudo ./etcd-backup.sh
# Schedule it daily from a root-owned copy, so root's cron never runs a file in a user's home:
#   sudo install -m 0755 k8s/scripts/etcd-backup.sh /usr/local/sbin/etcd-backup.sh
#   echo '30 2 * * * root /usr/local/sbin/etcd-backup.sh' | sudo tee /etc/cron.d/etcd-backup
set -euo pipefail

BACKUP_DIR=/var/backups/kubernetes
KEEP_DAYS=14

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
stamp=$(date +%F-%H%M%S)
install -d -m 0700 "$BACKUP_DIR"
# The snapshot is written in etcd's data folder (the container sees it), under a name of its
# own, so overlapping runs can't clash; it's removed from there if anything fails
snap=/var/lib/etcd/backup-$stamp-$$.db
trap 'rm -f "$snap"' EXIT

# etcdctl runs inside the etcd container, which has the client certificates mounted.
# crictl reaches it through containerd, so this works even when the API server is down.
cid=$(crictl ps --name '^etcd$' --state Running -q | head -1)
[ -n "$cid" ] || { echo "etcd isn't running on this node." >&2; exit 1; }
crictl exec "$cid" etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save "$snap"
# Check the snapshot is readable before keeping it
crictl exec "$cid" etcdutl snapshot status "$snap" -w table
mv "$snap" "$BACKUP_DIR/etcd-$stamp.db"

# Certificates, kubeconfigs and static pod manifests are needed to restore the snapshot
tar -czf "$BACKUP_DIR/kubernetes-etc-$stamp.tgz" -C / etc/kubernetes
chmod 600 "$BACKUP_DIR"/*"$stamp"*

find "$BACKUP_DIR" -type f -mtime +"$KEEP_DAYS" -delete
ls -lh "$BACKUP_DIR"/*"$stamp"*
echo "Copy $BACKUP_DIR off this VM (it holds the cluster's private keys)."
