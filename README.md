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

- **Existing database and ORDS.** ORDS in the cluster connects to the database your current ORDS server uses: `node.1apx.com:1521`, service `pdb1`, as `ORDS_PUBLIC_USER`. You need that user's existing password. The SYS password is only needed if the ORDS schema has to be installed or upgraded (see Step 6). The workers must be able to reach port 1521 on the database server.
- **Versions in the database.** The ORDS image version must match the ORDS version installed in the database, and the APEX images must match its APEX version. Step 6 checks both and tells you if anything needs changing.
- **Certificate.** Put the `*.1apx.com` files in `ssl/` at the top of this repo. `.gitignore` keeps that folder, and any `*.key`, `*.p12` and `*.jks` file, out of git. Step 6 uses `ssl/1apx_com.crt`, `ssl/1apx_com.ca-bundle` and `ssl/1apx.key`. The certificate covers `*.1apx.com` and `1apx.com` and expires on **2 January 2027**.
- **Reserve the addresses** `192.168.1.171`, `192.168.1.172` and `192.168.1.180`–`192.168.1.189` on the router, or exclude them from its DHCP pool. All of them answered no ping when this was written.
- **DNS records.** None of the cluster names resolve today: `1apx.com` is on Cloudflare, but `k8-control`, the workers, `node.1apx.com` and `ords.1apx.com` have no records. You need:
  - `ords.1apx.com` → `192.168.1.180`, the name users and browsers will use for ORDS. Put it on your LAN DNS server (the router), or in Cloudflare if you don't mind the private address being public.
  - `node.1apx.com` → the database server's IP. Or set `DB_HOST_IP` in `deploy-ords.sh`, which maps the name for the ORDS pods only.
  - Optionally, the three nodes. The scripts add them to `/etc/hosts` on every node anyway.
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

Script: [`k8s/ords/deploy-ords.sh`](k8s/ords/deploy-ords.sh). It uses [`k8s/ords/ords-settings.conf`](k8s/ords/ords-settings.conf), [`k8s/ords/ords.yaml`](k8s/ords/ords.yaml), [`k8s/ords/ords-preflight.yaml`](k8s/ords/ords-preflight.yaml) and [`k8s/ords/ords-install-job.yaml`](k8s/ords/ords-install-job.yaml).
Check the variables at the top of `deploy-ords.sh`, which already hold your current database details. Then, on k8-control, run `k8s/ords/deploy-ords.sh` as `vaviles`.

**ORDS settings.** `ords-settings.conf` holds your existing server's `settings.xml` and `pool.xml` settings, one `key value` per line. Every pod applies them when it starts. Changes from the old server:

- **Same:** context path `/apps`, APEX static files at `/i`, `plsql.gateway.mode direct` with `ords_util.authorize_plsql_gateway`, `misc.defaultPage apex`, `security.forceHTTPS true`, `database.api.enabled true`, Database Actions and REST-enabled SQL off, and all the `jdbc.*` timeouts and limits.
- **Halved:** the connection pool, because there are now two ORDS pods. Each pod gets `InitialLimit 15`, `MinLimit 25` and `MaxLimit 150`, which add up to the old server's 30 / 50 / 300. Raise them if one pod has to carry all the traffic.
- **Port 8443** for HTTPS inside the pod, instead of 443, so ORDS runs without root. The service still listens on 443.
- **Left out:** `standalone.use.https` and `standalone.use.ssl.cert` (old settings, unused by current ORDS), the old server's file paths (`standalone.access.log`, `standalone.doc.root`), the empty `misc.compress`, and the `default` → `plsql.gateway.mode` line, which isn't a real setting.

**What the script does:**

1. **Certificate.** Checks that it covers `ords.1apx.com` and hasn't expired, and warns 30 days before expiry. Checks that the key matches. Joins the certificate and intermediates into one chain, converts the key to PKCS#8, and stores both as the `ords-tls` Secret. The conversion matters: tested with this ORDS image, a PKCS#1 key (`BEGIN RSA PRIVATE KEY`, like `ssl/1apx.pem`) stops ORDS from starting.
2. **ORDS_PUBLIC_USER password.** Asks for it twice, without echoing or saving it, and stores it as a Secret.
3. **Preflight check.** A short-lived pod logs in to `node.1apx.com:1521/pdb1` as `ORDS_PUBLIC_USER`. That proves the network path and the password, and reports the ORDS and APEX versions installed in the database. If the login fails, the script shows the database's error and stops. This first pod also downloads the ORDS image (about 700 MB).
4. **APEX images.** Uses the database's APEX version, unless you set `APEX_VERSION`, and checks that Oracle publishes `apex_<version>.zip` for it. Each worker downloads the images once (about 300 MB) into `/var/cache/ords-apex`, and pods on that worker reuse them. The workers need HTTPS access to `download.oracle.com`.
5. **ORDS version.** If the database's ORDS version differs from the image (`ORDS_IMAGE`, 26.2.3 by default), the script stops. Either set `ORDS_IMAGE` to the database's version (tags 25.1.1 to 26.3.0 are available), or set `INSTALL_OR_UPGRADE_SCHEMA=true`. In that case it asks for the SYS password, runs the one-time install/upgrade Job, and **then deletes the SYS password** from the cluster. Upgrading the schema affects every ORDS server using this database, so upgrade your existing server to the same version.
6. **Deploys ORDS:**
   - **Two replicas**, spread across the two workers, with a PodDisruptionBudget so one keeps running during node maintenance.
   - **No shared storage.** Each pod writes its own ORDS config when it starts, and never sees the SYS password.
   - **Runs `ords serve` directly** instead of the image's entrypoint. The entrypoint turns on Database Actions, REST-enabled SQL and the MongoDB API at every start, which would override your settings.
   - **Locked down:** runs as the image's `oracle` user (UID 54321) with no extra Linux capabilities and a 3 GiB memory limit. Only the step that writes the APEX images into the worker's cache runs as root.
   - **Health checks** connect over HTTPS and send `Host: ords.1apx.com`, because ORDS rejects HTTPS requests whose host doesn't match the certificate. Readiness uses `/apps/_/landing`, which fails (`571`) when ORDS can't reach the database, so traffic only goes to pods with a working connection.
   - **Service** on `192.168.1.180`: port **443** for HTTPS, and port 80, which redirects to `https://ords.1apx.com/...`. It has client-IP session affinity, so APEX sessions stay on one pod.

**Rehearsed on k8-control (2026-10-15):** the pod's config script was run with `ords-settings.conf` and the real certificate, then ORDS 26.2.3 was started from it. ORDS served the full Sectigo chain, which verified cleanly against the public CAs. HTTP redirected to HTTPS, and the health checks behaved as described. The database login itself hasn't been tested, because `node.1apx.com` doesn't resolve from here.

ORDS is then at **`https://ords.1apx.com/apps/`**, with APEX at `https://ords.1apx.com/apps/r/...` (or `/apps/f?p=...`), the same paths as on the old server.

To change a setting, edit `ords-settings.conf` and run the script again. It replaces the pods one at a time.

### Step 7: Check the cluster

On k8-control, as `vaviles`:

- `kubectl get nodes -o wide` shows three `Ready` nodes.
- `kubectl get pods -A` shows everything `Running`.
- `kubectl get pods -n ords -o wide` shows one ORDS pod on each worker, both `1/1 Ready`. A pod stays `0/1` while it can't reach the database.
- `kubectl logs -n ords deploy/ords` shows "HTTPS listening on host: 0.0.0.0 port: 8443" and no pool errors.
- `curl -sI https://ords.1apx.com/apps/` returns a `302` to the APEX start page. Running `curl -vI` also shows the `*.1apx.com` certificate.
- `kubectl top nodes` shows CPU and memory for each node.

### Running the cluster

- **Backups.** Script: [`k8s/etcd-backup.sh`](k8s/etcd-backup.sh). Run `sudo k8s/etcd-backup.sh` on k8-control. It saves an etcd snapshot (the whole cluster state) plus `/etc/kubernetes` (certificates and config) to `/var/backups/kubernetes`, and keeps 14 days. Schedule it daily with cron (the script's header shows the line). Copy the backups off the VM, because they contain the cluster's private keys. Also set up scheduled Proxmox backups (vzdump) of all three VMs.
- **Certificates** that kubeadm creates expire after one year, and upgrading the control plane renews them. Check them with `sudo kubeadm certs check-expiration`.
- **Upgrades.** Move up one minor version at a time (1.36 → 1.37), control plane first, then each worker. Drain each worker with `kubectl drain <node> --ignore-daemonsets` first; the ORDS PodDisruptionBudget keeps one replica up. Change `K8S_MINOR` and `K8S_VERSION` in `node-prep.sh` and the version in `kubeadm-config.yaml`, and upgrade Calico when its tested versions require it.
- **OS updates.** `apt upgrade` is safe because the Kubernetes packages are held. Reboot one node at a time, draining workers first.
- **Certificate renewal.** The `*.1apx.com` certificate expires on 2 January 2027. Put the renewed files in `ssl/` with the same names, or change `CERT_FILE`, `CHAIN_FILE` and `KEY_FILE`. Then run `deploy-ords.sh` again, which updates the `ords-tls` Secret and restarts the pods one at a time.
- **ORDS upgrades.** Set `ORDS_IMAGE` to the new tag and `INSTALL_OR_UPGRADE_SCHEMA=true`, run `deploy-ords.sh`, then set it back to `false`. Upgrade the old ORDS server too, or retire it.
- **Secrets.** Never commit passwords or keys to this repo; `ssl/` is git-ignored. To change the `ORDS_PUBLIC_USER` password, change it in the database, run `kubectl delete secret ords-db-runtime -n ords`, then run `deploy-ords.sh` again. The old ORDS server needs the new password too.
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

