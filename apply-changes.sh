#!/usr/bin/env bash
set -euo pipefail

USER_NAME=vaviles
IFACE=ens18
MAC=bc:24:11:4a:ff:07
ADDR=192.168.1.170/24
GW=192.168.1.1
DNS="192.168.1.1, 8.8.8.8"
NETPLAN=/etc/netplan/00-installer-config.yaml

# Pre-check: make sure the target IP is free
if ping -c2 -W1 "${ADDR%/*}" >/dev/null; then
  echo "${ADDR%/*} is already in use, aborting" >&2
  exit 1
fi

# 1. Passwordless sudo: validate a temp file before installing it, so a typo can't break sudo
f=$(mktemp)
echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$f"
visudo -cf "$f"
install -m 0440 -o root -g root "$f" "/etc/sudoers.d/$USER_NAME-nopasswd"
rm -f "$f"
visudo -c

# 2 + 3. Static IP and DNS: back up the current netplan config, then write the new one
cp -a "$NETPLAN" "/root/$(basename "$NETPLAN").bak-$(date +%F-%H%M%S)"
cat > "$NETPLAN" <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      match:
        macaddress: $MAC
      set-name: $IFACE
      dhcp4: false
      dhcp6: true
      addresses:
        - $ADDR
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$DNS]
EOF
chmod 600 "$NETPLAN"
netplan generate
netplan apply
sleep 3

# Verify
sudo -l -U "$USER_NAME" | tail -2
ip -br addr show "$IFACE"
ip route | grep default
ping -c2 -W2 "$GW"
resolvectl dns "$IFACE"
resolvectl query ubuntu.com | head -2
