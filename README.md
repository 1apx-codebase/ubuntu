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

These two were made by hand. The scripts below name their backups `/root/00-installer-config.yaml.bak-<date>-<time>`.

Notes:

- Sudo applies the last matching rule. `vaviles` is still in the `sudo` group, so `sudo -l -U vaviles` lists both `(ALL : ALL) ALL` and `NOPASSWD: ALL`, and no password is asked for.
- Before the change, `192.168.1.170` was confirmed unused (no ping reply, no ARP entry). Reserve it on the router, or exclude it from the DHCP pool, so no other device gets it.
- IPv6 still uses DHCPv6.

## Apply all changes

Script: [`apply-changes.sh`](apply-changes.sh). Run it with `sudo ./apply-changes.sh`.

Run as root from the **console**, not over SSH, because the IP address changes.
If you have to use SSH, change `netplan apply` in the script to `netplan try`, which rolls back after 120 seconds unless you confirm.
Edit the variables at the top to use the script on another machine.
It's safe to re-run: the check that the new IP is free is skipped when the machine already has it.
To change DNS later, edit `nameservers.addresses` in the netplan file (servers are tried in order), then run `netplan generate && netplan apply`.

## Revert all changes

Script: [`revert-changes.sh`](revert-changes.sh). Run it with `sudo ./revert-changes.sh`.

This removes the sudo rule and restores the original DHCP config, after backing up the current netplan file to `/root`. Its variables must match the ones in `apply-changes.sh`.

## Kubernetes cluster for Oracle ORDS

How to build a three-node Kubernetes cluster on Proxmox, with k8-control as the control plane and two worker VMs, and run Oracle REST Data Services (ORDS) on it, connected to an existing Oracle database.
The cluster is built with `kubeadm`, the upstream Kubernetes installer. Every script is safe to re-run.

Files in [`k8s/`](k8s/) are kept apart by type, so a change to a manifest or setting never means editing a script:

| Folder | Contents |
|--------|----------|
| [`k8s/scripts/`](k8s/scripts/) | Shell scripts, one per step, which you run |
| [`k8s/manifests/`](k8s/manifests/) | Kubernetes and kubeadm YAML, which the scripts apply. [`manifests/ords/`](k8s/manifests/ords/) holds the ORDS ones |
| [`k8s/config/`](k8s/config/) | Application settings. [`ords-settings.conf`](k8s/config/ords-settings.conf) holds the ORDS settings |

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

### Accounts

| Account | Where | Used for |
|---------|-------|----------|
| `k8sadmin` | All three nodes | Dedicated cluster admin account. The scripts use it to log in to the workers. It has no password (SSH key only) and passwordless sudo |
| `vaviles` | k8-control | Your personal login. It runs `kubectl`, the add-on and ORDS scripts, and git |

A dedicated account is the better practice. The cluster doesn't depend on a personal login, and its SSH key is separate from personal keys such as `vaviles`'s GitHub key. On the workers, cloud-init creates only `k8sadmin`. To reach a worker, run `sudo -iu k8sadmin` on k8-control, then `ssh k8-worker-1`.

### DNS

Every node uses the same DNS servers as k8-control: **`192.168.1.1`** (the router) first, then **`8.8.8.8`** (Google).

| Node | Where it's set |
|------|----------------|
| k8-control | `/etc/netplan/00-installer-config.yaml` (see the top of this README) |
| Workers | cloud-init, from `proxmox-create-workers.sh` (`--nameserver "192.168.1.1 8.8.8.8"`, search domain `1apx.com`) |

`node-prep.sh` warns if a node is missing either server. Kubernetes uses them too: kubeadm points kubelet at `/run/systemd/resolve/resolv.conf`, which lists the real servers rather than the local `127.0.0.53` stub. Pods resolve outside names through CoreDNS, which forwards to those servers.

**Caveat with two DNS servers.** Ubuntu's resolver asks one server and only switches when it fails. `8.8.8.8` only knows the public `1apx.com` zone on Cloudflare. So a record that exists only on the router, such as `ords.1apx.com`, can stop resolving whenever the node has switched to `8.8.8.8`. To avoid this, either put the records in Cloudflare (they would be public, though the addresses are private), or remove `8.8.8.8` from the nodes. The node names don't depend on DNS, because the scripts write them to `/etc/hosts`. The database name doesn't either if you set `DB_HOST_IP`.

### Kernel settings

`node-prep.sh` applies these on every node, now and at every boot.

| Setting | Value | Why |
|---------|-------|-----|
| Module `overlay` | loaded (`/etc/modules-load.d/k8s.conf`) | Filesystem containerd uses for container images |
| Module `br_netfilter` | loaded (same file) | Lets iptables see traffic crossing Linux bridges |
| `net.ipv4.ip_forward` | `1` (`/etc/sysctl.d/99-kubernetes.conf`) | Routes packets between pods, nodes and the LAN. Kubernetes doesn't work without it |
| `net.bridge.bridge-nf-call-iptables` | `1` | Sends bridged pod traffic through iptables, so services and network policies apply |
| `net.bridge.bridge-nf-call-ip6tables` | `1` | The same for IPv6 |
| `fs.inotify.max_user_watches` | `524288` | Ubuntu's default (about 60,000 on k8-control) runs out with many containers |
| `fs.inotify.max_user_instances` | `512` | The default is 128 |
| Swap | off (`swapoff -a`, commented out in `/etc/fstab`) | kubelet won't start with swap on by default |

Checked on k8-control before the change: `ip_forward` was `0`, the two modules weren't loaded, ufw was installed but inactive, and the inotify limits were the defaults (59,452 and 128). Reverse-path filtering stays at Ubuntu's default (loose), which Calico expects.

### Firewall

`node-prep.sh` turns on ufw on every node. It denies incoming traffic by default and opens only what the cluster needs. Set `ENABLE_FIREWALL=false` in the script to leave ufw alone.

| Port | Protocol | From | Nodes | Purpose |
|------|----------|------|-------|---------|
| 22 | TCP | LAN `192.168.1.0/24` | All | SSH |
| 6443 | TCP | LAN | Control plane | Kubernetes API (nodes, `kubectl`) |
| 10250 | TCP | Other nodes | All | kubelet API (logs, exec, metrics) |
| 4789 | UDP | Other nodes | All | Calico VXLAN (pod traffic between nodes) |
| 179 | TCP | Other nodes | All | Calico BGP |
| 5473 | TCP | Other nodes | All | Calico Typha |
| 7946 | TCP and UDP | Other nodes | All | MetalLB node coordination |
| 30000–32767 | TCP | LAN | Workers | NodePort services (ORDS doesn't use them) |
| all | all | Pods `10.244.0.0/16` | All | Pods reaching their node (API server, DNS, kubelet) |

Things to know:

- **ufw's forward policy** is changed from `DROP` to `ACCEPT` in `/etc/default/ufw`. Kubernetes sends service traffic, including ORDS on `192.168.1.180:443`, through the kernel's FORWARD chain, so ufw's default would silently break it. Because of this, ORDS's ports 80 and 443 need no rule.
- **Not opened:** etcd (2379–2380), the scheduler (10259) and the controller manager (10257). They listen only on k8-control itself.
- **Use the console when enabling it.** SSH from the LAN is allowed before ufw is turned on, but if anything goes wrong, use the Proxmox console.
- **When troubleshooting:** if pods can't reach each other or a service, run `sudo ufw disable` on the nodes for a moment. If that fixes it, a rule is missing. Check with `sudo ufw status numbered`.

### Before you start

- **Existing database and ORDS.** ORDS in the cluster connects to the database your current ORDS server uses: `node.1apx.com:1521`, service `pdb1`, as `ORDS_PUBLIC_USER`. You need that user's existing password. The SYS password is only needed if the ORDS schema has to be installed or upgraded (see Step 7). The workers must be able to reach port 1521 on the database server.
- **Versions in the database.** The ORDS image version must match the ORDS version installed in the database, and the APEX images must match its APEX version. Step 7 checks both and tells you if anything needs changing.
- **Certificate.** Put the `*.1apx.com` files in `ssl/` at the top of this repo. `.gitignore` keeps that folder, and any `*.key`, `*.pem`, `*.p12`, `*.jks` and `*.pfx` file, out of git. Step 7 uses `ssl/1apx_com.crt`, `ssl/1apx_com.ca-bundle` and `ssl/1apx.key`. The certificate covers `*.1apx.com` and `1apx.com` and expires on **2 January 2027**.
- **Reserve the addresses** `192.168.1.171`, `192.168.1.172` and `192.168.1.180`–`192.168.1.189` on the router, or exclude them from its DHCP pool. All of them answered no ping when this was written.
- **DNS records.** None of the cluster names resolve today: `1apx.com` is on Cloudflare, but `k8-control`, the workers, `node.1apx.com` and `ords.1apx.com` have no records. You need:
  - `ords.1apx.com` → `192.168.1.180`, the name users and browsers will use for ORDS (see the caveat under [DNS](#dns)).
  - `node.1apx.com` → the database server's IP. Or set `DB_HOST_IP` in `deploy-ords.sh`, which maps the name for the ORDS pods only.
  - Optionally, the three nodes. The scripts add them to `/etc/hosts` on every node anyway.
- **Proxmox details.** Check the VM storage name with `pvesm status` and the LAN bridge with `ip -br link` on the Proxmox host. The script assumes `local-lvm` and `vmbr0`, and needs Proxmox VE 7.2 or later.
- **Password SSH to k8-control.** The VM script fetches `k8sadmin`'s public key by logging in to `vaviles@192.168.1.170`, so the Proxmox host must be able to log in there with a password once.

In the steps below, run commands from the repo folder on k8-control, `/home/vaviles/codebase/github/ubuntu`.

### Step 1: Create the admin account (on k8-control)

Script: [`k8s/scripts/create-admin-user.sh`](k8s/scripts/create-admin-user.sh). Run `sudo k8s/scripts/create-admin-user.sh`.

It creates `k8sadmin` with a locked password (SSH key login only), adds it to the `sudo` group, and gives it passwordless sudo through `/etc/sudoers.d/k8sadmin`, which `visudo` checks first. It also generates the account's own SSH key, `~k8sadmin/.ssh/id_ed25519`, which the next step installs on the workers.

### Step 2: Create the worker VMs (on the Proxmox host)

Script: [`k8s/scripts/proxmox-create-workers.sh`](k8s/scripts/proxmox-create-workers.sh). Copy it to the Proxmox host (for example with `scp` from k8-control) and run it there as root.

It fetches `k8sadmin`'s public key from k8-control, downloads the Ubuntu 26.04 cloud image, checks it against Ubuntu's published `SHA256SUMS`, and makes a template VM (ID 9000) from it. Then it creates full clones as VM 211 (`k8-worker-1`) and VM 212 (`k8-worker-2`), each with:

- 4 cores (CPU type `host`), 8 GB RAM with ballooning off, and a 60 GB disk. Kubernetes schedules by memory, so memory that can shrink causes problems.
- A static IP, gateway `192.168.1.1`, DNS servers `192.168.1.1` and `8.8.8.8`, and search domain `1apx.com`, all set through cloud-init. This matches k8-control.
- The `k8sadmin` account with that SSH key and passwordless sudo. Cloud images don't allow SSH password logins.
- The QEMU guest agent enabled, and the VM set to start when the Proxmox host boots.

The script stops if a worker's IP already answers ping. Cloud images are used instead of cloning k8-control, because a clone would copy its machine ID, SSH host keys and static IP.

Check: after a minute, on k8-control, `sudo -iu k8sadmin ssh 192.168.1.171 hostname` prints `k8-worker-1`.

### Step 3: Prepare k8-control

Script: [`k8s/scripts/node-prep.sh`](k8s/scripts/node-prep.sh). Run `sudo k8s/scripts/node-prep.sh` from the **Proxmox console**, because it turns on the firewall. Step 5 runs the same script on the workers for you.

It does what every Kubernetes node needs:

1. Adds the three nodes to `/etc/hosts`, and to cloud-init's template for it (`/etc/cloud/templates/hosts.debian.tmpl`). On the workers, cloud-init rewrites `/etc/hosts` from that template at every boot, so without this a worker would lose the names after a reboot and couldn't reach `k8-control.1apx.com`.
2. Checks that the DNS servers are `192.168.1.1` and `8.8.8.8` (see [DNS](#dns)).
3. Turns swap off. k8-control has a 4 GB swap file.
4. Loads the kernel modules and applies the kernel settings (see [Kernel settings](#kernel-settings)).
5. Installs containerd and sets it to systemd cgroups (the same as kubelet). It also sets containerd's pause image to the one kubeadm expects, `pause:3.10.2`; containerd's default is `3.10.1`.
6. Installs `kubelet`, `kubeadm` and `kubectl` 1.36.5 from `pkgs.k8s.io`, and holds them so `apt upgrade` can't change them.
7. Makes kubelet use the node's LAN IP, not the `127.0.1.1` entry Ubuntu puts in `/etc/hosts`.
8. Creates `/var/cache/ords-apex`, owned by the ORDS image's `oracle` user (UID 54321), where the ORDS pods keep the APEX images (see Step 7).
9. Turns on the firewall (see [Firewall](#firewall)).

It ends with a summary. Check that swap shows 0, both modules are listed, `ip_forward` is 1, the firewall is active, and the machine ID is different on every node.

### Step 4: Create the control plane

Script: [`k8s/scripts/control-plane-init.sh`](k8s/scripts/control-plane-init.sh), which uses [`k8s/manifests/kubeadm-config.yaml`](k8s/manifests/kubeadm-config.yaml). Run `sudo k8s/scripts/control-plane-init.sh`.

1. Checks the kubeadm config, pulls the control-plane images and runs `kubeadm init`.
   The API server is reached as `k8-control.1apx.com:6443`, a name rather than an IP, so more control-plane nodes can be added later without rebuilding.
2. Copies the admin kubeconfig to `~/.kube/config` for `vaviles` and `k8sadmin`, so `kubectl` works for both.
3. Installs Calico with the pod network set to `10.244.0.0/16`, and waits until the node is `Ready`. Since Calico 3.30, its operator's resource definitions come in a separate file, `operator-crds.yaml`, which is installed first.

The control plane keeps its default taint, so ORDS and other workloads only run on the workers.

### Step 5: Join the workers

Script: [`k8s/scripts/join-workers.sh`](k8s/scripts/join-workers.sh). Run `sudo k8s/scripts/join-workers.sh`.

For each worker, it logs in as `k8sadmin` with that account's key, waits for cloud-init's first-boot work (including its package upgrade) to finish, then copies `node-prep.sh` there and runs it, including the firewall. Then it creates a join token that expires after 30 minutes, runs `kubeadm join` on the worker, and deletes the token. Finally it waits for both workers to be `Ready` and labels them as workers.

The first SSH connection to each worker saves its host key. If you want to check it, compare it with the key shown on the VM's Proxmox console.

Check: `kubectl get nodes -o wide` lists all three nodes as `Ready` with their `192.168.1.x` addresses.

### Step 6: Install the add-ons

Script: [`k8s/scripts/cluster-addons.sh`](k8s/scripts/cluster-addons.sh). Run `k8s/scripts/cluster-addons.sh` as `vaviles`.

- **MetalLB** in layer-2 mode, with the pool `192.168.1.180`–`192.168.1.189`. A `LoadBalancer` service gets one of these LAN IPs, and the worker running it answers ARP for it.
- **metrics-server**, so `kubectl top nodes` and `kubectl top pods` work. It skips verifying kubelets' self-signed serving certificates, which is the usual setting for kubeadm clusters.

### Step 7: Deploy ORDS

Script: [`k8s/scripts/deploy-ords.sh`](k8s/scripts/deploy-ords.sh). It uses the settings in [`k8s/config/ords-settings.conf`](k8s/config/ords-settings.conf) and the manifests [`ords.yaml`](k8s/manifests/ords/ords.yaml), [`ords-preflight.yaml`](k8s/manifests/ords/ords-preflight.yaml) and [`ords-install-job.yaml`](k8s/manifests/ords/ords-install-job.yaml) in `k8s/manifests/ords/`.
Check the variables at the top of `deploy-ords.sh`, which already hold your current database details. Then run `k8s/scripts/deploy-ords.sh` as `vaviles`.

**ORDS settings.** `k8s/config/ords-settings.conf` holds your existing server's `settings.xml` and `pool.xml` settings, one `key value` per line. Every pod applies them when it starts. Changes from the old server:

- **Same:** context path `/apps`, APEX static files at `/i`, `plsql.gateway.mode direct` with `ords_util.authorize_plsql_gateway`, `misc.defaultPage apex`, `security.forceHTTPS true`, `database.api.enabled true`, Database Actions and REST-enabled SQL off, and all the `jdbc.*` timeouts and limits.
- **Halved:** the connection pool, because there are now two ORDS pods. Each pod gets `InitialLimit 15`, `MinLimit 25` and `MaxLimit 150`, which add up to the old server's 30 / 50 / 300. Raise them if one pod has to carry all the traffic.
- **Port 8443** for HTTPS inside the pod, instead of 443, so ORDS runs without root. The service still listens on 443.
- **Left out:** `standalone.use.https` and `standalone.use.ssl.cert` (old settings, unused by current ORDS), the old server's file paths (`standalone.access.log`, `standalone.doc.root`), the empty `misc.compress`, and the `default` → `plsql.gateway.mode` line, which isn't a real setting.

**What the script does:**

1. **Certificate.** Checks that it covers `ords.1apx.com` and hasn't expired, and warns 30 days before expiry. Checks that the key matches. Joins the certificate and intermediates into one chain, converts the key to PKCS#8, and stores both as the `ords-tls` Secret. The conversion matters: tested with this ORDS image, a PKCS#1 key (`BEGIN RSA PRIVATE KEY`, like `ssl/1apx.pem`) stops ORDS from starting.
2. **ORDS_PUBLIC_USER password.** Asks for it twice, without echoing or saving it, and stores it as a Secret.
3. **Preflight check.** A short-lived pod logs in to `node.1apx.com:1521/pdb1` as `ORDS_PUBLIC_USER`. That proves the network path and the password, and reports the ORDS and APEX versions installed in the database. If the login fails, the script shows the database's error and stops. This first pod also downloads the ORDS image (about 700 MB). If the pod hasn't finished after 10 minutes (usually because the image can't be downloaded), the script shows the pod's events and stops.
4. **APEX images.** Uses the database's APEX version, unless you set `APEX_VERSION`, and checks that Oracle publishes `apex_<version>.zip` for it. Each worker downloads the images once (about 300 MB) into `/var/cache/ords-apex`, and pods on that worker reuse them. The workers need HTTPS access to `download.oracle.com`.
5. **ORDS version.** If the database's ORDS version differs from the image (`ORDS_IMAGE`, 26.2.3 by default), the script stops. Either set `ORDS_IMAGE` to the database's version (tags 25.1.1 to 26.3.0 are available), or set `INSTALL_OR_UPGRADE_SCHEMA=true`. In that case it asks for the SYS password, runs the one-time install/upgrade Job (stopping as soon as it fails, or after 30 minutes), and **then deletes the SYS password** from the cluster. Upgrading the schema affects every ORDS server using this database, so upgrade your existing server to the same version.
6. **Deploys ORDS:**
   - **Two replicas**, normally one on each worker, with a PodDisruptionBudget so one keeps running during node maintenance. The spread is a preference, so both replicas can run on one worker while the other is drained or down.
   - **No shared storage.** Each pod writes its own ORDS config when it starts, and never sees the SYS password.
   - **Runs `ords serve` directly** instead of the image's entrypoint. The entrypoint turns on Database Actions, REST-enabled SQL and the MongoDB API at every start, which would override your settings.
   - **Locked down:** every container runs as the image's `oracle` user (UID 54321), never as root, with no Linux capabilities, no Kubernetes API token, and memory limits (3 GiB for ORDS). The APEX images cache, `/var/cache/ords-apex` on each worker, is created by `node-prep.sh` and owned by that user.
   - **Rolling updates without dropped requests:** a stopping pod keeps serving for 10 seconds while the Service and MetalLB stop sending it new connections.
   - **Health checks** connect over HTTPS and send `Host: ords.1apx.com`, because ORDS rejects HTTPS requests whose host doesn't match the certificate. Readiness uses `/apps/_/landing`, which fails (`571`) when ORDS can't reach the database, so traffic only goes to pods with a working connection.
   - **Service** on `192.168.1.180`: port **443** for HTTPS, and port 80, which redirects to `https://ords.1apx.com/...`. It has client-IP session affinity, so APEX sessions stay on one pod.

**Rehearsed on k8-control (2026-10-15):** the pod's config script was run with `ords-settings.conf` and the real certificate, then ORDS 26.2.3 was started from it. ORDS served the full Sectigo chain, which verified cleanly against the public CAs. HTTP redirected to HTTPS, and the health checks behaved as described. The database login itself hasn't been tested, because `node.1apx.com` doesn't resolve from here.

ORDS is then at **`https://ords.1apx.com/apps/`**, with APEX at `https://ords.1apx.com/apps/r/...` (or `/apps/f?p=...`), the same paths as on the old server.

To change a setting, edit `ords-settings.conf` and run the script again. It replaces the pods one at a time, but only when the settings, certificate, password or database details have changed: a hash of them is stored on the pods, so running the script again with nothing changed restarts nothing.

### Step 8: Check the cluster

On k8-control, as `vaviles`:

- `kubectl get nodes -o wide` shows three `Ready` nodes.
- `kubectl get pods -A` shows everything `Running`.
- `kubectl get pods -n ords -o wide` shows one ORDS pod on each worker, both `1/1 Ready`. If both are on one worker (after that worker was down, for example), run `kubectl rollout restart deployment/ords -n ords` to spread them again. A pod stays `0/1` while it can't reach the database.
- `kubectl logs -n ords deploy/ords` shows "HTTPS listening on host: 0.0.0.0 port: 8443" and no pool errors.
- `curl -sI https://ords.1apx.com/apps/` returns a `302` to the APEX start page. Running `curl -vI` also shows the `*.1apx.com` certificate.
- `kubectl top nodes` shows CPU and memory for each node.

### Running the cluster

- **Backups.** Script: [`k8s/scripts/etcd-backup.sh`](k8s/scripts/etcd-backup.sh). Run `sudo k8s/scripts/etcd-backup.sh` on k8-control. It saves an etcd snapshot (the whole cluster state) plus `/etc/kubernetes` (certificates and config) to `/var/backups/kubernetes`, and keeps 14 days. It talks to etcd through containerd (`crictl`), so it works even when the API server is down, and checks each snapshot with `etcdutl snapshot status` before keeping it. To run it daily, copy it to `/usr/local/sbin` and add a cron line; the script's header shows both commands. Cron runs the root-owned copy, never the file in `vaviles`'s home, so re-run the `install` command after changing the script. Copy the backups off the VM, because they contain the cluster's private keys. Also set up scheduled Proxmox backups (vzdump) of all three VMs.
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


## Appendix A: Copying text from Claude Code

On 2026-10-15, text couldn't be copied out of Claude Code (run as `sudo claude`) with the mouse.

**Cause.** A fresh install of Claude Code starts in its fullscreen interface, which captures the mouse. Dragging selects text inside Claude Code, which then tries to copy it to the clipboard with an OSC 52 escape code. The terminal used here doesn't accept OSC 52, so nothing reached the clipboard. Pasting into Claude Code was not affected.

**Fix.** Switch Claude Code to its classic interface, so the terminal handles selection and copy itself:

| Change | File | Used by |
|--------|------|---------|
| Add `"tui": "default"` | `/root/.claude/settings.json` | `sudo claude` |
| Add `"tui": "default"` | `/home/vaviles/.claude/settings.json` | `claude` as `vaviles` |

Both files now read:

```json
{
  "theme": "auto",
  "tui": "default"
}
```

The originals are backed up at `/root/.claude/settings.json.bak-2026-10-15-015041` and `/home/vaviles/.claude/settings.json.bak-2026-10-15-015744`.

Script: [`claude-classic-tui.sh`](claude-classic-tui.sh). Run it with `sudo ./claude-classic-tui.sh`, or `sudo ./claude-classic-tui.sh --revert` to go back to fullscreen. It changes both files, backs each one up first, and keeps each file's owner.

Notes:

- **Restart Claude Code after the change.** If the setting changes while a session is running, the screen can go blank. Press Ctrl+L to redraw, or exit and run `sudo claude` again, then use `/resume` to continue the conversation.
- **Settings are per user.** `sudo claude` reads `/root/.claude/settings.json`, and `claude` as `vaviles` reads `/home/vaviles/.claude/settings.json`, so both need the setting. To cover another user, add them to `TARGETS` at the top of the script.
- **Without this fix**, you can still copy in the fullscreen interface by holding a key while you drag: Shift in most Linux and Windows terminals and PuTTY, Option in iTerm2, Fn in macOS Terminal.app.
