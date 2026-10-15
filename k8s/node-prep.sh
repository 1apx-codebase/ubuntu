#!/usr/bin/env bash
# Prepare an Ubuntu 26.04 machine to be a Kubernetes node (control plane or worker).
# Run as root on every node: sudo ./node-prep.sh
# join-workers.sh runs it on the workers for you. Safe to re-run.
set -euo pipefail

K8S_MINOR=v1.36                   # package channel on pkgs.k8s.io
K8S_VERSION=1.36.5                # exact version, the same on every node
HOSTS_BLOCK="192.168.1.170 k8-control.1apx.com k8-control
192.168.1.171 k8-worker-1.1apx.com k8-worker-1
192.168.1.172 k8-worker-2.1apx.com k8-worker-2"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# This node's IP comes from the list above and must be on this machine
NODE_IP=$(awk -v h="$(hostname -s)" '$3 == h {print $1}' <<<"$HOSTS_BLOCK")
[ -n "$NODE_IP" ] || { echo "Hostname $(hostname -s) is not in HOSTS_BLOCK." >&2; exit 1; }
ip -4 -br addr | grep -q " $NODE_IP/" || { echo "$NODE_IP is not configured on this machine." >&2; exit 1; }
echo "Preparing $(hostname -s) ($NODE_IP)"

# 1. Cluster names in /etc/hosts (there are no DNS records for 1apx.com)
sed -i '/^# BEGIN k8s-cluster$/,/^# END k8s-cluster$/d' /etc/hosts
printf '# BEGIN k8s-cluster\n%s\n# END k8s-cluster\n' "$HOSTS_BLOCK" >> /etc/hosts

# 2. Swap off, now and after reboots (kubelet won't start with swap on by default)
swapoff -a
sed -ri '/^[^#].*\sswap\s/ s/^/#/' /etc/fstab

# 3. Kernel modules and network settings for pod networking
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# 4. Container runtime (containerd from Ubuntu) and base tools
apt-get update -q
apt-get install -y -q ca-certificates curl gpg containerd runc qemu-guest-agent
systemctl start qemu-guest-agent 2>/dev/null || true

# 5. Kubernetes packages, pinned and held so apt upgrade can't change them
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

# 6. containerd config: systemd cgroups (matches kubelet) and kubeadm's pause image
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

# 7. kubelet: always use the LAN address, not 127.0.1.1 from /etc/hosts
echo "KUBELET_EXTRA_ARGS=--node-ip=$NODE_IP" > /etc/default/kubelet
systemctl enable kubelet

# 8. Summary
echo "---"
echo "hostname:   $(hostname -s) ($NODE_IP)"
echo "swap:       $(swapon --noheadings | wc -l) active (should be 0)"
echo "ip_forward: $(sysctl -n net.ipv4.ip_forward)"
echo "containerd: $(containerd --version | awk '{print $3}'), pause $pause"
echo "kubeadm:    $(kubeadm version -o short)"
echo "time sync:  $(timedatectl show -p NTPSynchronized --value)"
echo "machine-id: $(cat /etc/machine-id) (must differ on every node)"
