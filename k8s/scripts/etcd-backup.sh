#!/usr/bin/env bash
# Back up the cluster state: an etcd snapshot plus the control plane's certificates and config,
# kubelet's credentials and config, k8sadmin's SSH key, and the etcdutl that restores the snapshot.
# Restoring: README, Appendix C.4.
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

# Restoring needs: the certificates, kubeconfigs, static pod manifests and the Secrets
# encryption key (/etc/kubernetes), kubelet's client certificate and config (/var/lib/kubelet),
# and k8sadmin's SSH key, which the workers accept
files=(etc/kubernetes var/lib/kubelet/pki var/lib/kubelet/config.yaml var/lib/kubelet/kubeadm-flags.env)
ssh_dir=$(getent passwd k8sadmin | cut -d: -f6 || true)/.ssh
[ ! -d "$ssh_dir" ] || files+=("${ssh_dir#/}")
tar -czf "$BACKUP_DIR/kubernetes-config-$stamp.tgz" -C / "${files[@]}"
chmod 600 "$BACKUP_DIR"/*"$stamp"*
# etcdutl from the running etcd image, the version that matches the snapshot. A restore runs it
# while etcd is stopped, so it has to be on the host. Kept once, refreshed when etcd changes.
pid=$(crictl inspect --output go-template --template '{{.info.pid}}' "$cid")
if [ -x "/proc/$pid/root/usr/local/bin/etcdutl" ]; then
  install -m 0700 "/proc/$pid/root/usr/local/bin/etcdutl" "$BACKUP_DIR/etcdutl"
else
  echo "WARNING: couldn't copy etcdutl from the etcd container; a restore will need it." >&2
fi

find "$BACKUP_DIR" -type f -name "*-20*" -mtime +"$KEEP_DAYS" -delete
ls -lh "$BACKUP_DIR"/*"$stamp"*
echo "Copy $BACKUP_DIR off this VM (it holds the cluster's private keys)."
