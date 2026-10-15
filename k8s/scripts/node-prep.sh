#!/usr/bin/env bash
# Prepare an Ubuntu 26.04 machine to be a Kubernetes node (control plane or worker):
# names, DNS check, swap, kernel modules and settings, firewall, containerd and the
# Kubernetes packages.
# Run as root on every node: sudo ./node-prep.sh
# join-workers.sh runs it on the workers for you. Safe to re-run.
set -euo pipefail

K8S_MINOR=v1.36                   # package channel on pkgs.k8s.io
K8S_VERSION=1.36.5                # exact version, the same on every node
CONTROL_PLANE=k8-control
HOSTS_BLOCK="192.168.1.170 k8-control.1apx.com k8-control
192.168.1.171 k8-worker-1.1apx.com k8-worker-1
192.168.1.172 k8-worker-2.1apx.com k8-worker-2"
DNS_SERVERS="192.168.1.1 8.8.8.8" # expected on every node (netplan or cloud-init)
LAN=192.168.1.0/24
POD_CIDR=10.244.0.0/16            # must match kubeadm-config.yaml
ENABLE_FIREWALL=true              # ufw host firewall; set false to leave ufw alone

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# This node's IP comes from the list above and must be on this machine
NODE_IP=$(awk -v h="$(hostname -s)" '$3 == h {print $1}' <<<"$HOSTS_BLOCK")
[ -n "$NODE_IP" ] || { echo "Hostname $(hostname -s) is not in HOSTS_BLOCK." >&2; exit 1; }
ip -4 -br addr | grep -q " $NODE_IP/" || { echo "$NODE_IP is not configured on this machine." >&2; exit 1; }
NODE_IPS=$(awk '{print $1}' <<<"$HOSTS_BLOCK")
echo "Preparing $(hostname -s) ($NODE_IP)"

# 1. Cluster names in /etc/hosts (there are no DNS records for them). On the workers,
#    cloud-init rewrites /etc/hosts from its template at every boot (Proxmox sets
#    manage_etc_hosts: true), so the template gets the same block.
for f in /etc/hosts /etc/cloud/templates/hosts.debian.tmpl; do
  [ -f "$f" ] || continue
  sed -i '/^# BEGIN k8s-cluster$/,/^# END k8s-cluster$/d' "$f"
  printf '# BEGIN k8s-cluster\n%s\n# END k8s-cluster\n' "$HOSTS_BLOCK" >> "$f"
done

# 2. DNS: check the node uses the expected servers. kubeadm points kubelet (and so
#    CoreDNS) at /run/systemd/resolve/resolv.conf, which lists these real servers.
for s in $DNS_SERVERS; do
  resolvectl dns 2>/dev/null | grep -qwF "$s" \
    || echo "WARNING: DNS server $s isn't configured on this node (see resolvectl dns)."
done
getent hosts pkgs.k8s.io >/dev/null || { echo "DNS lookups are failing." >&2; exit 1; }

# 3. Swap off, now and after reboots (kubelet won't start with swap on by default)
swapoff -a
sed -ri '/^[^#].*\sswap\s/ s/^/#/' /etc/fstab

# 4. Kernel modules: overlay (container filesystems) and br_netfilter (lets
#    iptables see bridged pod traffic), loaded now and at every boot
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter

# 5. Kernel settings, applied now and at every boot
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
# Route packets between pods, nodes and the LAN
net.ipv4.ip_forward                 = 1
# Pass bridged traffic through iptables, so Kubernetes services and policies apply
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
# More inotify watches and instances (kubelet, containerd and many containers use them)
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
EOF
sysctl --system >/dev/null

# 6. Base packages: containerd from Ubuntu, ufw, the QEMU guest agent for Proxmox
apt-get update -q
apt-get install -y -q ca-certificates curl gpg containerd runc ufw qemu-guest-agent
systemctl start qemu-guest-agent 2>/dev/null || true

# 7. Kubernetes packages, pinned and held so apt upgrade can't change them
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
apt-get install -y -q --allow-downgrades \
  "kubelet=$K8S_VERSION-*" "kubeadm=$K8S_VERSION-*" "kubectl=$K8S_VERSION-*"
apt-mark hold kubelet kubeadm kubectl

# 8. containerd config: systemd cgroups (matches kubelet) and kubeadm's pause image
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
pause=$(kubeadm config images list --kubernetes-version "v$K8S_VERSION" 2>/dev/null | grep '/pause:')
sed -i "s|sandbox = '.*'|sandbox = '$pause'|" /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
grep -q "sandbox = '$pause'" /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF

# 9. kubelet: always use the LAN address, not 127.0.1.1 from /etc/hosts
echo "KUBELET_EXTRA_ARGS=--node-ip=$NODE_IP" > /etc/default/kubelet
systemctl enable kubelet

# 10. Host folder for the ORDS pods' APEX images cache (hostPath in ords.yaml), owned
#     by the image's oracle user (54321), so the pods never need to run as root
install -d -m 0755 -o 54321 -g 54321 /var/cache/ords-apex

# 11. Host firewall (ufw): deny incoming by default, allow only what the cluster needs
if [ "$ENABLE_FIREWALL" = true ]; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  # Kubernetes routes service and pod traffic through the FORWARD chain; ufw's default
  # (DROP) would break it. This sets DEFAULT_FORWARD_POLICY="ACCEPT" in /etc/default/ufw.
  ufw default allow routed >/dev/null
  ufw allow from "$LAN" to any port 22 proto tcp comment 'SSH from LAN' >/dev/null
  # Pods talking to this node (API server via the kubernetes service, kubelet, DNS)
  ufw allow from "$POD_CIDR" comment 'Kubernetes pods' >/dev/null
  for ip in $NODE_IPS; do
    [ "$ip" = "$NODE_IP" ] && continue
    ufw allow from "$ip" to any port 10250 proto tcp comment 'kubelet API' >/dev/null
    ufw allow from "$ip" to any port 4789 proto udp comment 'Calico VXLAN' >/dev/null
    ufw allow from "$ip" to any port 179 proto tcp comment 'Calico BGP' >/dev/null
    ufw allow from "$ip" to any port 5473 proto tcp comment 'Calico Typha' >/dev/null
    ufw allow from "$ip" to any port 7946 comment 'MetalLB memberlist' >/dev/null
  done
  if [ "$(hostname -s)" = "$CONTROL_PLANE" ]; then
    # API server: nodes and admins on the LAN. etcd, the scheduler and the controller
    # manager get no rule, so only this node can reach them.
    ufw allow from "$LAN" to any port 6443 proto tcp comment 'Kubernetes API' >/dev/null
  fi
  ufw --force enable >/dev/null
fi

# 12. Summary
echo "---"
echo "hostname:    $(hostname -s) ($NODE_IP)"
echo "DNS servers: $(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2!="" {print $2}' | xargs)"
echo "swap:        $(swapon --noheadings | wc -l) active (should be 0)"
echo "modules:     $(lsmod | awk '$1=="overlay"||$1=="br_netfilter" {print $1}' | xargs)"
echo "ip_forward:  $(sysctl -n net.ipv4.ip_forward), bridge-nf-call-iptables: $(sysctl -n net.bridge.bridge-nf-call-iptables)"
echo "firewall:    $(ufw status | head -1)"
echo "containerd:  $(containerd --version | awk '{print $3}'), pause $pause"
echo "kubeadm:     $(kubeadm version -o short)"
echo "time sync:   $(timedatectl show -p NTPSynchronized --value)"
echo "machine-id:  $(cat /etc/machine-id) (must differ on every node)"
