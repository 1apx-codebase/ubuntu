#!/usr/bin/env bash
# Create the two Kubernetes worker VMs from an Ubuntu 26.04 cloud image.
# Run on the Proxmox host as root: ./proxmox-create-workers.sh
# Safe to re-run: the template and any VM that already exists are skipped.
set -euo pipefail

STORAGE=zfs-pool-data             # ZFS storage for the VM disks (see: pvesm status)
BRIDGE=vmbr0                      # LAN bridge (see: ip -br link)
TEMPLATE_ID=9000
IMAGE_URL=https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img
IMAGE=/var/lib/vz/template/iso/ubuntu-26.04-server-cloudimg-amd64.img
CI_USER=k8sadmin                  # dedicated admin account (create-admin-user.sh on k8-control)
CONTROL_LOGIN=vaviles@192.168.1.170   # used once to fetch k8sadmin's public key
GATEWAY=192.168.1.1
DNS="192.168.1.1 8.8.8.8"
DOMAIN=1apx.com
CORES=4
MEMORY=8192                       # MiB
DISK=60G
#        VMID name        IP
WORKERS=("211 k8-worker-1 192.168.1.171"
         "212 k8-worker-2 192.168.1.172")

[ "$(id -u)" -eq 0 ] || { echo "Run as root on the Proxmox host." >&2; exit 1; }
command -v qm >/dev/null || { echo "qm not found: this must run on the Proxmox host." >&2; exit 1; }
# The storage must exist and accept VM disks
pvesm status --content images | awk 'NR>1 {print $1}' | grep -qx "$STORAGE" \
  || { echo "Storage '$STORAGE' not found, or it doesn't hold VM disks (pvesm status --content images)." >&2; exit 1; }
ip link show "$BRIDGE" >/dev/null || { echo "Bridge '$BRIDGE' not found." >&2; exit 1; }
# The ORDS image (Oracle Linux 10) needs an x86-64-v3 CPU (AVX2). The workers use CPU type
# "host", so this host's CPU must have it.
for flag in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
  grep -qw "$flag" /proc/cpuinfo \
    || { echo "This host's CPU lacks $flag (x86-64-v3), which the ORDS image needs." >&2; exit 1; }
done

# k8sadmin's public key from k8-control, which cloud-init installs on each worker
key=$(mktemp)
trap 'rm -f "$key"' EXIT
ssh -o StrictHostKeyChecking=accept-new "$CONTROL_LOGIN" "sudo cat /home/$CI_USER/.ssh/id_ed25519.pub" > "$key" \
  || { echo "Run create-admin-user.sh on k8-control first." >&2; exit 1; }
ssh-keygen -lf "$key"

# Template VM from the cloud image (built once)
if ! qm status "$TEMPLATE_ID" >/dev/null 2>&1; then
  [ -f "$IMAGE" ] || wget -q --show-progress -O "$IMAGE" "$IMAGE_URL"
  # Check the image against Ubuntu's published checksum before using it
  sum=$(wget -qO- "${IMAGE_URL%/*}/SHA256SUMS" | awk -v f="*${IMAGE_URL##*/}" '$2 == f {print $1}')
  if [ -z "$sum" ] || ! echo "$sum  $IMAGE" | sha256sum -c --quiet -; then
    echo "$IMAGE doesn't match Ubuntu's SHA256SUMS; delete it and re-run." >&2
    exit 1
  fi
  qm create "$TEMPLATE_ID" --name ubuntu-2604-cloud --ostype l26 --cpu host --cores 2 --memory 2048 \
    --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single --agent enabled=1 \
    --serial0 socket --vga serial0
  qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:0,import-from=$IMAGE,discard=on,ssd=1,iothread=1"
  qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
  qm template "$TEMPLATE_ID"
  echo "Created template $TEMPLATE_ID"
fi

for w in "${WORKERS[@]}"; do
  read -r id name ip <<<"$w"
  if qm status "$id" >/dev/null 2>&1; then
    echo "VM $id ($name) already exists, skipping"
    continue
  fi
  if ping -c2 -W1 "$ip" >/dev/null 2>&1; then
    echo "$ip is already in use, not creating $name" >&2
    exit 1
  fi
  # Full clone: each worker gets its own disk, machine-id and SSH host keys
  qm clone "$TEMPLATE_ID" "$id" --name "$name" --full --storage "$STORAGE"
  qm set "$id" --cores "$CORES" --memory "$MEMORY" --balloon 0 --onboot 1 \
    --ciuser "$CI_USER" --sshkeys "$key" \
    --ipconfig0 "ip=$ip/24,gw=$GATEWAY" --nameserver "$DNS" --searchdomain "$DOMAIN"
  qm resize "$id" scsi0 "$DISK"
  qm start "$id"
  echo "Started $name ($ip) as VM $id"
done

echo "Wait a minute for cloud-init, then on k8-control run: sudo -iu $CI_USER ssh 192.168.1.171 hostname"
