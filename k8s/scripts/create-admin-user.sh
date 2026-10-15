#!/usr/bin/env bash
# Create k8sadmin, the dedicated account the cluster scripts use to manage the nodes.
# Run on k8-control as root, before creating the worker VMs: sudo ./create-admin-user.sh
# The worker VMs get the same account from cloud-init (proxmox-create-workers.sh).
# Safe to re-run.
#
# Why a separate account: the cluster doesn't depend on a personal login, and its SSH key
# is separate from personal keys (such as vaviles's GitHub key). It has no password
# (SSH keys only) and passwordless sudo, which the automation needs.
set -euo pipefail

ADMIN_USER=k8sadmin

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

# 1. Account: no password (SSH key login only), member of sudo
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --comment "Kubernetes cluster admin" "$ADMIN_USER"
  echo "Created $ADMIN_USER"
fi
usermod -aG sudo "$ADMIN_USER"
passwd -l "$ADMIN_USER" >/dev/null
home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
chmod 0750 "$home"

# 2. Passwordless sudo, validated before installing so a typo can't break sudo
f=$(mktemp)
echo "$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL" > "$f"
visudo -cf "$f" >/dev/null
install -m 0440 -o root -g root "$f" "/etc/sudoers.d/$ADMIN_USER"
rm -f "$f"
visudo -c >/dev/null

# 3. SSH key used to log in to the workers
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
if [ ! -f "$home/.ssh/id_ed25519" ]; then
  sudo -u "$ADMIN_USER" ssh-keygen -q -t ed25519 -N "" -C "$ADMIN_USER@$(hostname -s)" -f "$home/.ssh/id_ed25519"
fi
# The same key may log in here too, so the account works the same way on every node
touch "$home/.ssh/authorized_keys"
grep -qxF "$(cat "$home/.ssh/id_ed25519.pub")" "$home/.ssh/authorized_keys" \
  || cat "$home/.ssh/id_ed25519.pub" >> "$home/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"
chmod 0600 "$home/.ssh/authorized_keys"

echo "---"
id "$ADMIN_USER"
sudo -l -U "$ADMIN_USER" | tail -1
ssh-keygen -lf "$home/.ssh/id_ed25519.pub"
echo "Public key (proxmox-create-workers.sh fetches it): $home/.ssh/id_ed25519.pub"
