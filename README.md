# k8-control: Ubuntu post-install changes

Changes made to the host `k8-control` (Ubuntu 26.04.1 LTS) after installation, on 2026-10-15.

| # | Change | File |
|---|--------|------|
| 1 | Passwordless sudo for `vaviles` | `/etc/sudoers.d/vaviles-nopasswd` (root:root, `0440`) |
| 2 | Static IP `192.168.1.170/24` on `ens18`, gateway `192.168.1.1` (was DHCP, `192.168.1.223`) | `/etc/netplan/00-installer-config.yaml` (`0600`) |
| 3 | DNS servers `192.168.1.1`, `8.8.8.8` | same netplan file |

Backups on the host:

- `/root/00-installer-config.yaml.bak-dhcp` is the original DHCP config.
- `/root/00-installer-config.yaml.bak-static-dns1` is the static config with router-only DNS, from before change 3.

Notes:

- Sudo applies the last matching rule. `vaviles` is still in the `sudo` group, so `sudo -l -U vaviles` lists both `(ALL : ALL) ALL` and `NOPASSWD: ALL`, and no password is asked for.
- Before the change, `192.168.1.170` was confirmed unused (no ping reply, no ARP entry). Reserve it on the router, or exclude it from the DHCP pool, so no other device gets it.
- IPv6 still uses DHCPv6.

## Apply all changes

Script: [`apply-changes.sh`](apply-changes.sh). Run it with `sudo ./apply-changes.sh`.

Run as root from the **console**, not over SSH, because the IP address changes.
If you have to use SSH, change `netplan apply` in the script to `netplan try`, which rolls back after 120 seconds unless you confirm.
Edit the variables at the top to use the script on another machine.
To change DNS later, edit `nameservers.addresses` in the netplan file (servers are tried in order), then run `netplan generate && netplan apply`.

## Revert all changes

Script: [`revert-changes.sh`](revert-changes.sh). Run it with `sudo ./revert-changes.sh`.

This removes the sudo rule and restores the original DHCP config.

## Kubernetes cluster for Oracle ORDS

How to build a three-node Kubernetes cluster on Proxmox, with k8-control as the control plane and two worker VMs, and run Oracle REST Data Services (ORDS) on it, connected to an existing Oracle database.
The cluster is built with `kubeadm`, the upstream Kubernetes installer. Each step is a script in [`k8s/`](k8s/), and every script is safe to re-run.

### Cluster design

| Node | Role | IP | VM size |
|------|------|----|---------|
| `k8-control.1apx.com` | Control plane (this VM) | `192.168.1.170` | 8 vCPU, 7.2 GB RAM, 48 GB disk (already exists) |
| `k8-worker-1.1apx.com` | Worker, runs ORDS | `192.168.1.171` | 4 vCPU, 8 GB RAM, 60 GB disk |
| `k8-worker-2.1apx.com` | Worker, runs ORDS | `192.168.1.172` | 4 vCPU, 8 GB RAM, 60 GB disk |

Yes, each worker is its own Ubuntu VM in Proxmox. Kubernetes nodes must be separate machines, each with its own hostname, MAC address, machine ID and IP.
Two workers let ORDS keep running while one is down or being upgraded. For protection against a Proxmox host failure as well, put the VMs on different Proxmox hosts.

| Network | Range | Notes |
|---------|-------|-------|
| LAN | `192.168.1.0/24`, gateway `192.168.1.1` | Node addresses |
| Pods | `10.244.0.0/16` | Changed from Calico's default `192.168.0.0/16`, which overlaps the LAN and would break routing |
| Services | `10.96.0.0/12` | Internal cluster addresses (kubeadm default) |
| LoadBalancer pool | `192.168.1.180` – `192.168.1.189` | LAN addresses MetalLB hands to services. ORDS uses `192.168.1.180` |

| Component | Version | Why this version |
|-----------|---------|------------------|
| Ubuntu | 26.04.1 LTS | Same as k8-control |
| Kubernetes | 1.36.5 | One minor version behind the newest (1.37). Calico 3.32 is tested against it |
| containerd | 2.2.2 (Ubuntu package) | Container runtime, set to systemd cgroups |
| Calico | 3.32.2 | Pod network and network policy |
| MetalLB | 0.16.0 | Gives `LoadBalancer` services a LAN IP (layer 2) |
| metrics-server | 0.9.0 | `kubectl top` and autoscaling |
| ORDS | 26.2.3 (`container-registry.oracle.com/database/ords`) | Oracle's official image |

All versions are pinned in the scripts, so every node gets exactly the same software.

### Before you start

- **Database details.** ORDS runs in the cluster and connects to your existing Oracle database. You need its hostname, listener port (usually 1521) and the **PDB service name** (not the CDB). The SYS password is needed once, to install the ORDS schema. The workers must be able to reach the database's listener port.
- **Reserve the addresses** `192.168.1.171`, `192.168.1.172` and `192.168.1.180`–`192.168.1.189` on the router, or exclude them from its DHCP pool. All of them answered no ping when this was written.
- **DNS (recommended).** There are no DNS records for `*.1apx.com`. The scripts add the three nodes to `/etc/hosts` on every node, but A records on your DNS server let other machines use the names too.
- **Proxmox details.** Check the VM storage name with `pvesm status` and the LAN bridge with `ip -br link` on the Proxmox host. The script assumes `local-lvm` and `vmbr0`, and needs Proxmox VE 7.2 or later.
- **Password SSH to k8-control.** The VM script copies k8-control's public key with `scp`, so the Proxmox host must be able to log in to `vaviles@192.168.1.170` with a password once.

### Step 1: Create the worker VMs (on the Proxmox host)

Script: [`k8s/proxmox-create-workers.sh`](k8s/proxmox-create-workers.sh). Copy it to the Proxmox host (for example with `scp` from k8-control) and run it there as root.

It downloads the Ubuntu 26.04 cloud image and makes a template VM (ID 9000) from it. Then it creates full clones as VM 211 (`k8-worker-1`) and VM 212 (`k8-worker-2`), each with:

- 4 cores (CPU type `host`), 8 GB RAM with ballooning off, and a 60 GB disk. Kubernetes schedules by memory, so memory that can shrink causes problems.
- A static IP, gateway, DNS servers `192.168.1.1` and `8.8.8.8`, and search domain `1apx.com`, all set through cloud-init. This matches what was done on k8-control.
- User `vaviles` with k8-control's SSH key and passwordless sudo, so k8-control can manage the workers.
- The QEMU guest agent enabled, and the VM set to start when the Proxmox host boots.

The script stops if a worker's IP already answers ping. Cloud images are used instead of cloning k8-control, because a clone would copy its machine ID, SSH host keys and static IP.

Check: after a minute, `ssh vaviles@192.168.1.171 hostname` from k8-control prints `k8-worker-1`.

### Step 2: Prepare k8-control

Script: [`k8s/node-prep.sh`](k8s/node-prep.sh). On k8-control, run `sudo k8s/node-prep.sh`. Step 4 runs the same script on the workers for you.

It does what every Kubernetes node needs:

1. Adds the three nodes to `/etc/hosts`.
2. Turns swap off and comments it out of `/etc/fstab`. k8-control has a 4 GB swap file, and kubelet won't start with swap on by default.
3. Loads the `overlay` and `br_netfilter` kernel modules and enables IP forwarding and bridged traffic filtering.
4. Installs containerd and sets it to systemd cgroups (the same as kubelet). It also sets containerd's pause image to the one kubeadm expects, `pause:3.10.2`; containerd's default is `3.10.1`.
5. Installs `kubelet`, `kubeadm` and `kubectl` 1.36.5 from `pkgs.k8s.io`, and holds them so `apt upgrade` can't change them.
6. Makes kubelet use the node's LAN IP, not the `127.0.1.1` entry Ubuntu puts in `/etc/hosts`.

It ends with a summary. Check that swap shows 0 and that the machine ID is different on every node.

### Step 3: Create the control plane

Script: [`k8s/control-plane-init.sh`](k8s/control-plane-init.sh), which uses [`k8s/kubeadm-config.yaml`](k8s/kubeadm-config.yaml). On k8-control, run `sudo k8s/control-plane-init.sh`.

1. Checks the kubeadm config, pulls the control-plane images and runs `kubeadm init`.
   The API server is reached as `k8-control.1apx.com:6443`, a name rather than an IP, so more control-plane nodes can be added later without rebuilding.
2. Copies the admin kubeconfig to `~vaviles/.kube/config`, so `kubectl` works as `vaviles`.
3. Installs Calico with the pod network set to `10.244.0.0/16`, and waits until the node is `Ready`.

The control plane keeps its default taint, so ORDS and other workloads only run on the workers.

### Step 4: Join the workers

Script: [`k8s/join-workers.sh`](k8s/join-workers.sh). On k8-control, run `k8s/join-workers.sh` as `vaviles`, without sudo.

For each worker, it connects over SSH and runs `node-prep.sh` there. Then it creates a single-use join token that expires after 30 minutes and runs `kubeadm join` on the worker. Finally it waits for both workers to be `Ready` and labels them as workers.

The first SSH connection to each worker saves its host key. If you want to check it, compare it with the key shown on the VM's Proxmox console.

Check: `kubectl get nodes -o wide` lists all three nodes as `Ready` with their `192.168.1.x` addresses.

### Step 5: Install the add-ons

Script: [`k8s/cluster-addons.sh`](k8s/cluster-addons.sh). On k8-control, run `k8s/cluster-addons.sh` as `vaviles`.

- **MetalLB** in layer-2 mode, with the pool `192.168.1.180`–`192.168.1.189`. A `LoadBalancer` service gets one of these LAN IPs, and the worker running it answers ARP for it.
- **metrics-server**, so `kubectl top nodes` and `kubectl top pods` work. It skips verifying kubelets' self-signed serving certificates, which is the usual setting for kubeadm clusters.

### Step 6: Deploy ORDS

Script: [`k8s/ords/deploy-ords.sh`](k8s/ords/deploy-ords.sh), which uses [`k8s/ords/ords-install-job.yaml`](k8s/ords/ords-install-job.yaml) and [`k8s/ords/ords.yaml`](k8s/ords/ords.yaml).
First set `DB_HOST`, `DB_PORT` and `DB_SERVICE` at the top of `deploy-ords.sh`. Then, on k8-control, run `k8s/ords/deploy-ords.sh` as `vaviles`.

1. Creates the `ords` namespace.
2. Asks twice for each of two passwords, without echoing or saving them. One is a new password for `ORDS_PUBLIC_USER`, the account ORDS connects as. The other is your database's SYS password. Both are stored as Kubernetes Secrets, never in this repo.
3. Starts a test pod that checks the database listener is reachable from inside the cluster, and stops if it isn't. The test pod uses the ORDS image, so it also downloads that image ahead of time.
4. Saves the database host, port and service in a ConfigMap.
5. Runs a one-time Job that installs the ORDS schema in the database, or upgrades it if it's already there. Then it **deletes the SYS password Secret**, so SYS credentials don't stay in the cluster. A future upgrade asks for it again.
6. Deploys ORDS:
   - **Two replicas**, spread across the two workers, with a PodDisruptionBudget so at least one keeps running during node maintenance.
   - **No shared storage.** Each pod writes its own ORDS config from the ConfigMap and the `ORDS_PUBLIC_USER` password when it starts, and never sees the SYS password.
   - **Locked down:** runs as the image's `oracle` user (UID 54321) with no extra Linux capabilities, a memory limit of 3 GiB and the default seccomp profile.
   - **Probes:** a startup probe allows up to 10 minutes. The readiness probe uses `/ords/_/landing`, which returns an error when ORDS can't reach the database, so traffic only goes to pods with a working connection. (`/ords/` answers even when the database is down, so it isn't used for readiness.)
   - **Service:** a `LoadBalancer` on `192.168.1.180`, port 80, with client-IP session affinity so Database Actions sessions stay on one pod.

ORDS is then at `http://192.168.1.180/ords/`, and Database Actions (SQL Developer Web) is at `http://192.168.1.180/ords/sql-developer`.

To upgrade ORDS, change `ORDS_IMAGE` in `deploy-ords.sh` to a newer tag and run it again. It asks for the SYS password, upgrades the schema, then rolls the pods one at a time.

### Step 7: Check the cluster

On k8-control, as `vaviles`:

- `kubectl get nodes -o wide` shows three `Ready` nodes.
- `kubectl get pods -A` shows everything `Running`. The `ords-install` Job shows `Completed`.
- `kubectl get pods -n ords -o wide` shows one ORDS pod on each worker.
- `kubectl logs -n ords deploy/ords` includes "Database connection successful".
- `kubectl top nodes` shows CPU and memory for each node.
- `http://192.168.1.180/ords/` opens the ORDS landing page in a browser on the LAN.

### Running the cluster

- **Backups.** Script: [`k8s/etcd-backup.sh`](k8s/etcd-backup.sh). Run `sudo k8s/etcd-backup.sh` on k8-control. It saves an etcd snapshot (the whole cluster state) plus `/etc/kubernetes` (certificates and config) to `/var/backups/kubernetes`, and keeps 14 days. Schedule it daily with cron (the script's header shows the line). Copy the backups off the VM, because they contain the cluster's private keys. Also set up scheduled Proxmox backups (vzdump) of all three VMs.
- **Certificates** that kubeadm creates expire after one year, and upgrading the control plane renews them. Check them with `sudo kubeadm certs check-expiration`.
- **Upgrades.** Move up one minor version at a time (1.36 → 1.37), control plane first, then each worker. Drain each worker with `kubectl drain <node> --ignore-daemonsets` first; the ORDS PodDisruptionBudget keeps one replica up. Change `K8S_MINOR` and `K8S_VERSION` in `node-prep.sh` and the version in `kubeadm-config.yaml`, and upgrade Calico when its tested versions require it.
- **OS updates.** `apt upgrade` is safe because the Kubernetes packages are held. Reboot one node at a time, draining workers first.
- **HTTPS.** ORDS is served over plain HTTP on the LAN. Before exposing it beyond the LAN, add TLS: either a Gateway API controller with cert-manager in front of the ORDS service, or a certificate and key mounted in the ORDS config at `ssl/cert.crt` and `ssl/key.key`, which makes the image listen on 8443.
- **Secrets.** Never commit passwords to this repo. To change the `ORDS_PUBLIC_USER` password, change it in the database, delete the `ords-db-runtime` Secret, and run `deploy-ords.sh` again.
- **Single control plane.** If k8-control is down, running ORDS pods keep serving, but you can't change the cluster until it's back. For high availability, add two more control-plane nodes behind `k8-control.1apx.com` (kubeadm supports this because the endpoint is a name), and restore from the etcd backups if needed.
- **Starting over on a node.** `sudo kubeadm reset` removes Kubernetes state from a node. On the control plane, that deletes the cluster.

## GitHub access

This repo is pushed from k8-control to the private repo [`1apx-codebase/ubuntu`](https://github.com/1apx-codebase/ubuntu) over SSH.
Run every command as `vaviles`, not root, so the key and repo stay owned by that user.

| Item | Value |
|------|-------|
| Local repo | `/home/vaviles/codebase/github/ubuntu` |
| Remote | `origin` → `git@github.com:1apx-codebase/ubuntu.git` |
| Branch | `main`, tracking `origin/main` |
| SSH key | `~/.ssh/id_ed25519` (ed25519, no passphrase), added to the `1apx-codebase` GitHub account |
| Key fingerprint | `SHA256:KvkjMyF+FAECb2T15hknyvUzrue/6Hrq3KNxAjiQbo8` |
| Commit identity | Set for this repo only: `Virgil Aviles <virgil.aviles@proton.me>` |

### One-time setup

Script: [`setup-github.sh`](setup-github.sh). Run it as `vaviles` with `./setup-github.sh`, not with sudo.

It's safe to re-run, because each step is skipped if it's already done. The script:

1. Creates `~/.ssh/id_ed25519` if it doesn't exist.
2. Checks that GitHub accepts the key. If it doesn't, the script prints the public key, saves a copy to `~/github-ssh-key.txt` (with an `scp` command to fetch it from another computer) and waits until you've added it on GitHub. It deletes the copy afterwards.
3. Sets up the local repo and the commit name and email for this repo.
4. Points `origin` at `git@github.com:1apx-codebase/ubuntu.git`.
5. Checks the GitHub repo exists. If it doesn't, the script waits while you create it as an empty, private repo.
6. Pushes `main`, then reports whether the repo is private.

Two steps happen on github.com: adding the key under **Settings → SSH and GPG keys**, and creating the repo. To use a different account, repo, name or email, edit the variables at the top of the script.

The GitHub CLI (`gh`) is installed on this machine but not logged in. The SSH setup doesn't need it.

