#!/usr/bin/env bash
set -euo pipefail

rm -f /etc/sudoers.d/vaviles-nopasswd
visudo -c

cat > /etc/netplan/00-installer-config.yaml <<'EOF'
# This is the network config written by 'subiquity'
network:
  ethernets:
    ens18:
      dhcp4: true
      dhcp6: true
      match:
        macaddress: bc:24:11:4a:ff:07
      set-name: ens18
  version: 2
EOF
chmod 600 /etc/netplan/00-installer-config.yaml
netplan generate
netplan apply
