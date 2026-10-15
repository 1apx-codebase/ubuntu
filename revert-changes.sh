#!/usr/bin/env bash
# Undo apply-changes.sh: remove the sudo rule and go back to DHCP.
# Run as root from the console (the IP changes): sudo ./revert-changes.sh
set -euo pipefail

# Must match apply-changes.sh
USER_NAME=vaviles
IFACE=ens18
MAC=bc:24:11:4a:ff:07
NETPLAN=/etc/netplan/00-installer-config.yaml

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

# 1. Remove the passwordless sudo rule
rm -f "/etc/sudoers.d/$USER_NAME-nopasswd"
visudo -c

# 2 + 3. Back up the current netplan config, then restore the installer's DHCP config
cp -a "$NETPLAN" "/root/$(basename "$NETPLAN").bak-$(date +%F-%H%M%S)"
cat > "$NETPLAN" <<EOF
# This is the network config written by 'subiquity'
network:
  ethernets:
    $IFACE:
      dhcp4: true
      dhcp6: true
      match:
        macaddress: $MAC
      set-name: $IFACE
  version: 2
EOF
chmod 600 "$NETPLAN"
netplan generate
netplan apply
