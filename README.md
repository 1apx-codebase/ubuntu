# k8-control: Ubuntu post-install changes

Changes made to the host `k8-control` (Ubuntu 26.04.1 LTS) after installation, on 2026-10-15.

`<user>` stands for your personal login on k8-control. The scripts that need it set it near their top: `USER_NAME` in `apply-changes.sh` and `revert-changes.sh`, `KUBECONFIG_USERS` in `control-plane-init.sh`, `CONTROL_LOGIN` in `proxmox-create-workers.sh` and `TARGETS` in `claude-classic-tui.sh`. `ci/validate.sh` checks they agree.

## Contents

- [Changes made after installation](#changes-made-after-installation)
- [Apply all changes](#apply-all-changes)
- [Revert all changes](#revert-all-changes)
- [Kubernetes cluster for Oracle ORDS](#kubernetes-cluster-for-oracle-ords)
  - [Cluster design](#cluster-design)
  - [Kustomize layout](#kustomize-layout)
  - [Accounts](#accounts)
  - [DNS](#dns)
  - [Kernel settings](#kernel-settings)
  - [Firewall](#firewall)
  - [Public access through Cloudflare](#public-access-through-cloudflare)
  - [DNS records to add](#dns-records-to-add)
  - [The database](#the-database)
  - [Before you start](#before-you-start)
  - [Step 1: Create the admin account (on k8-control)](#step-1-create-the-admin-account-on-k8-control)
  - [Step 2: Create the worker VMs (on the Proxmox host)](#step-2-create-the-worker-vms-on-the-proxmox-host)
  - [Step 3: Prepare k8-control](#step-3-prepare-k8-control)
  - [Step 4: Create the control plane](#step-4-create-the-control-plane)
  - [Step 5: Join the workers](#step-5-join-the-workers)
  - [Step 6: Install the add-ons](#step-6-install-the-add-ons)
  - [Step 7: Deploy ORDS](#step-7-deploy-ords)
  - [Step 8: Check the cluster](#step-8-check-the-cluster)
  - [Running the cluster](#running-the-cluster)
- [Validation and CI](#validation-and-ci)
- [GitHub access](#github-access)
  - [One-time setup](#one-time-setup)
- [Ownership, changes and licensing](#ownership-changes-and-licensing)
  - [Ownership and contacts](#ownership-and-contacts)
  - [Change history](#change-history)
  - [Licensing](#licensing)
- [Appendix A: Copying text from Claude Code](#appendix-a-copying-text-from-claude-code)
- [Appendix B: ORDS on Kubernetes: security, operations and troubleshooting](#appendix-b-ords-on-kubernetes-security-operations-and-troubleshooting)
  - [B.1 Security practices applied](#b1-security-practices-applied)
  - [B.2 Day-to-day operations](#b2-day-to-day-operations)
  - [B.3 Troubleshooting](#b3-troubleshooting)
  - [B.4 Changing the number of ORDS pods](#b4-changing-the-number-of-ords-pods)
  - [B.5 Adding an environment (dev, uat)](#b5-adding-an-environment-dev-uat)
- [Appendix C: Recovery, monitoring and lifecycle](#appendix-c-recovery-monitoring-and-lifecycle)
  - [C.1 Credentials and where they live](#c1-credentials-and-where-they-live)
  - [C.2 Monitoring and alerts](#c2-monitoring-and-alerts)
  - [C.3 Access logs](#c3-access-logs)
  - [C.4 Backups and restore](#c4-backups-and-restore)
  - [C.5 Upgrades, step by step](#c5-upgrades-step-by-step)
  - [C.6 Testing changes](#c6-testing-changes)
  - [C.7 Retiring the old ORDS server](#c7-retiring-the-old-ords-server)
  - [C.8 Taking the cluster down](#c8-taking-the-cluster-down)

## Changes made after installation

| # | Change | File |
|---|--------|------|
| 1 | Passwordless sudo for `<user>` | `/etc/sudoers.d/<user>-nopasswd` (root:root, `0440`) |
| 2 | Static IP `192.168.1.170/24` on `ens18`, gateway `192.168.1.1` (was DHCP, `192.168.1.223`) | `/etc/netplan/00-installer-config.yaml` (`0600`) |
| 3 | DNS servers `192.168.1.1`, `8.8.8.8` | same netplan file |

Backups on the host:

- `/root/00-installer-config.yaml.bak-dhcp` is the original DHCP config.
- `/root/00-installer-config.yaml.bak-static-dns1` is the static config with router-only DNS, from before change 3.

Notes:

- Sudo applies the last matching rule. `<user>` is still in the `sudo` group, so `sudo -l -U <user>` lists both `(ALL : ALL) ALL` and `NOPASSWD: ALL`, and no password is asked for.
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

This removes the sudo rule and restores the original DHCP config, after backing up the current netplan file to `/root`. Its variables must match the ones in `apply-changes.sh`.

## Kubernetes cluster for Oracle ORDS

How to build a three-node Kubernetes cluster on Proxmox, with k8-control as the control plane and two worker VMs, and run Oracle REST Data Services (ORDS) on it, connected to an existing Oracle database.

![Architecture: three Ubuntu VMs on Proxmox. k8-control runs the control plane; k8-worker-1 and k8-worker-2 each run one ORDS pod in the ords namespace, behind the MetalLB address 192.168.1.180, connected to the Oracle database node.1apx.com:1521](docs/architecture.svg)

Files in [`k8s/`](k8s/):

| Folder | Contents |
|--------|----------|
| [`k8s/scripts/`](k8s/scripts/) | Shell scripts, one per step, which you run |
| [`k8s/common/`](k8s/common/), [`k8s/portal/`](k8s/portal/) | ORDS (the portal application) as Kustomize, in three levels: see [Kustomize layout](#kustomize-layout) |
| [`k8s/manifests/`](k8s/manifests/) | The cluster's own setup: the kubeadm config and the API audit policy, which the cluster scripts apply |
| [`k8s/manifests/addons/`](k8s/manifests/addons/) | Settings for the add-ons: MetalLB's LAN address pool |
| [`k8s/config/`](k8s/config/) | [`upstream.sha256`](k8s/config/upstream.sha256), which pins every upstream manifest the scripts download |
| [`ci/`](ci/) | [`validate.sh`](ci/validate.sh), which checks the whole repo (see [Validation and CI](#validation-and-ci)) |

### Cluster design

| Node | Role | IP | VM size |
|------|------|----|---------|
| `k8-control.1apx.com` | Control plane (this VM) | `192.168.1.170` | 8 vCPU, 7.2 GB RAM, 48 GB disk (already exists) |
| `k8-worker-1.1apx.com` | Worker, runs ORDS | `192.168.1.171` | 4 vCPU, 8 GB RAM, 60 GB disk |
| `k8-worker-2.1apx.com` | Worker, runs ORDS | `192.168.1.172` | 4 vCPU, 8 GB RAM, 60 GB disk |

Each worker is its own Ubuntu VM in Proxmox. To keep ORDS running if a Proxmox host fails, put the VMs on different Proxmox hosts.

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
| MetalLB | 0.16.1 | Gives `LoadBalancer` services a LAN IP (layer 2) |
| metrics-server | 0.9.0 | `kubectl top` and autoscaling |
| ORDS | 26.2.0 (`container-registry.oracle.com/database/ords`) | Oracle's official image, at the version of the ORDS schema in the database |
| APEX | 26.1 (in the database) | The pods download its static images from Oracle |

### Kustomize layout

ORDS is described with Kustomize, which is built into `kubectl`, in three levels. Each level builds on the one above it:

| Level | Folder | Holds |
|-------|--------|-------|
| 1 | [`k8s/common/`](k8s/common/) | What every application namespace gets, whatever runs in it: the namespace, with Pod Security `restricted` enforced, and a network policy that blocks all traffic except DNS |
| 2 | [`k8s/portal/base/`](k8s/portal/base/) | The portal application, the same in every environment: the ORDS Deployment, Service, PodDisruptionBudget and network policy, the ORDS settings (`ords-settings.conf`) and the Java options for database encryption. Values that differ per environment are placeholders here |
| 3 | [`k8s/portal/prod/`](k8s/portal/prod/) | Production: the namespace name (`ords`), its values in [`ords.env`](k8s/portal/prod/ords.env) (the database, its address `DB_IP`, the host name, the MetalLB address, the APEX version), its connection pool size (`ords-pool.conf`), its replica count, and the ORDS image's tag and digest |
| 3 | [`k8s/portal/dev/`](k8s/portal/dev/), [`k8s/portal/uat/`](k8s/portal/uat/) | Empty for now: placeholders for future environments (see [B.5](#b5-adding-an-environment-dev-uat)) |

[`k8s/portal/base/environment/`](k8s/portal/base/environment/) is a Kustomize component that every environment includes. It copies the values in the environment's `ords.env` to where the manifests need them: the pods' host entry for the database, their health checks' host name, the network policy's database address and the Service's MetalLB address. So each environment's values live in one file.

- **See what an environment deploys:** `kubectl kustomize k8s/portal/prod`.
- **See what would change in the cluster:** `k8s/scripts/deploy-ords.sh --diff`.
- **Deploy with `deploy-ords.sh`,** not `kubectl apply -k`. The script also creates the two Secrets, which aren't in git, and checks the certificate.
- **The ConfigMaps' names end in a hash of their contents**, so a settings change makes new pods (one at a time) without any extra step.
- **Removing an object** from the Kustomize files doesn't remove it from the cluster: `kubectl apply` only creates and updates. Delete it yourself, for example `kubectl delete networkpolicy <name> -n ords`. `deploy-ords.sh` cleans up only the generated ConfigMaps.

### Accounts

| Account | Where | Used for |
|---------|-------|----------|
| `k8sadmin` | All three nodes | Dedicated cluster admin account. The scripts use it to log in to the workers. It has no password (SSH key only) and passwordless sudo |
| `<user>` | k8-control | Your personal login. It runs `kubectl`, the add-on and ORDS scripts, and git |

On the workers, cloud-init creates only `k8sadmin`. To reach a worker, run `sudo -iu k8sadmin` on k8-control, then `ssh k8-worker-1`.

### DNS

Every node uses the same DNS servers as k8-control: **`192.168.1.1`** (the router) first, then **`8.8.8.8`** (Google).

| Node | Where it's set |
|------|----------------|
| k8-control | `/etc/netplan/00-installer-config.yaml` (see the top of this README) |
| Workers | cloud-init, from `proxmox-create-workers.sh` (`--nameserver "192.168.1.1 8.8.8.8"`, search domain `1apx.com`) |

`node-prep.sh` warns if a node is missing either server. Kubernetes uses them too: kubeadm points kubelet at `/run/systemd/resolve/resolv.conf`, which lists the real servers rather than the local `127.0.0.53` stub. Pods resolve outside names through CoreDNS, which forwards to those servers.

**Caveat with two DNS servers.** Ubuntu's resolver asks one server and only switches when it fails. `8.8.8.8` only knows the public `1apx.com` zone on Cloudflare. So a record that exists only on the router, such as `node.1apx.com` for the database, can stop resolving whenever the node has switched to `8.8.8.8`. The ORDS pods aren't affected: they map `node.1apx.com` to `DB_IP` (in the environment's `ords.env`) themselves. Anything else on the nodes that needs router-only names is, so remove `8.8.8.8` from the nodes if that matters. The node names don't depend on DNS, because the scripts write them to `/etc/hosts`. The name users open, `www.1apx.com`, is a public Cloudflare record, so it resolves the same from either server (see [Public access through Cloudflare](#public-access-through-cloudflare)).

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
| all | all | Pods `10.244.0.0/16` | All | Pods reaching their node (API server, DNS, kubelet) |

Things to know:

- **ufw's forward policy** is changed from `DROP` to `ACCEPT` in `/etc/default/ufw`. Kubernetes sends service traffic, including ORDS on `192.168.1.180:443`, through the kernel's FORWARD chain, so ufw's default would silently break it. Because of this, ORDS's port 443 needs no rule.
- **Not opened:** etcd (2379–2380), the scheduler (10259) and the controller manager (10257). The scheduler and controller manager listen only on k8-control's loopback address. etcd also listens on its LAN address, but with these ports closed only k8-control itself can reach it.
- **Use the console when enabling it.** SSH from the LAN is allowed before ufw is turned on, but if anything goes wrong, use the Proxmox console.
- **When troubleshooting:** if pods can't reach each other or a service, run `sudo ufw disable` on the nodes for a moment. If that fixes it, a rule is missing. Check with `sudo ufw status numbered`.

### Public access through Cloudflare

Users open **`https://www.1apx.com/`**, from the internet or the LAN. Their traffic goes through Cloudflare to your public IP, and the router forwards it to ORDS:

| Hop | What happens |
|-----|--------------|
| Browser → Cloudflare | `www.1apx.com` is a proxied Cloudflare record, so users connect to Cloudflare, which applies its DDoS and bot protection |
| Cloudflare → router | Cloudflare connects to your public IP on port 443, over HTTPS, checking the `*.1apx.com` certificate |
| Router → cluster | The router forwards port 443 to `192.168.1.180`, ORDS's MetalLB address |
| Cluster → ORDS | The Service accepts connections only from Cloudflare's addresses and the cluster's nodes, and passes them to one of the two ORDS pods |

Settings outside this repo:

| Where | Setting |
|-------|---------|
| Router | Forward TCP port **443** from the internet to **`192.168.1.180:443`**. Port 80 isn't needed, because Cloudflare redirects `http://` to `https://` |
| Cloudflare, DNS | `www.1apx.com`: an `A` record to your public IP, **Proxied** (orange cloud). Change it only at cutover (below) |
| Cloudflare, SSL/TLS | Encryption mode **Full (strict)**. With "Flexible", Cloudflare talks plain HTTP to ORDS, ORDS redirects it to HTTPS, and browsers loop forever. With "Full" (not strict), Cloudflare doesn't check the certificate |
| Cloudflare, SSL/TLS → Edge Certificates | **Always Use HTTPS** on |

Things to know:

- **Only Cloudflare can reach ORDS from the internet.** The Service lists Cloudflare's IPv4 ranges in `loadBalancerSourceRanges`, plus the three nodes for testing from k8-control, so anyone who finds your public IP and connects directly is refused. Not the whole LAN: some routers rewrite a forwarded connection's source address to their own LAN address, which would let anyone past the list. LAN users don't need it, because they reach `www.1apx.com` through Cloudflare too. Cloudflare publishes the ranges at <https://www.cloudflare.com/ips-v4>; `ci/validate.sh` fails if they change, and then you update `ords.yaml` and run `deploy-ords.sh`.
- **A changing public IP** breaks the Cloudflare record. If your ISP doesn't give you a fixed IP, keep the record current with a dynamic DNS updater for Cloudflare (many routers have one built in).
- **Client addresses.** ORDS and APEX see Cloudflare's addresses, not users'. Cloudflare passes the real address in the `CF-Connecting-IP` header.
- **Bot protection.** Today, `www.1apx.com` answers non-browser clients with Cloudflare's "Just a moment..." challenge. Browsers pass it, but scripts and other systems calling ORDS's REST APIs won't. If you have such clients, add a Cloudflare WAF rule that skips the challenge for their paths or addresses.

**Cutover.** `www.1apx.com` already points somewhere today, hidden behind Cloudflare. Note its current target in Cloudflare's DNS page, so you can switch back. Then:

1. Build the cluster and pass [Step 8](#step-8-check-the-cluster), which tests ORDS directly from k8-control.
2. Add the router's port forward.
3. Add the `test.1apx.com` record ([DNS records to add](#dns-records-to-add)), and open `https://test.1apx.com/apps/`. The certificate covers it, and the test exercises the whole path: Cloudflare, the router, the source ranges and ORDS.
4. Replace the `www.1apx.com` records as described in [DNS records to add](#dns-records-to-add), and delete the test record. To roll back, restore `www`'s old records.
5. From outside your network, check that ORDS can't be reached without Cloudflare (the last check in [Step 8](#step-8-check-the-cluster)).

### DNS records to add

Every DNS record the setup needs, in the order you add them. "Router" means the LAN's DNS server, `192.168.1.1`; "Cloudflare" means the `1apx.com` zone in Cloudflare's dashboard.

| When | Name | Type | Value | Where | Required |
|------|------|------|-------|-------|----------|
| [Before you start](#before-you-start) | `node.1apx.com` | A | The database server's IP | Router | Recommended: the pods use `DB_IP` from `ords.env`, and `deploy-ords.sh` checks the two agree |
| [Before you start](#before-you-start) (optional) | `k8-control.1apx.com` | A | `192.168.1.170` | Router | Only to run `kubectl` from another machine, or to reach k8-control by name |
| [Before you start](#before-you-start) (optional) | `k8-worker-1.1apx.com` | A | `192.168.1.171` | Router | No: to reach the worker by name |
| [Before you start](#before-you-start) (optional) | `k8-worker-2.1apx.com` | A | `192.168.1.172` | Router | No: to reach the worker by name |
| [Cutover](#public-access-through-cloudflare), step 3 | `test.1apx.com` | A | Your public IP | Cloudflare, **Proxied** | Yes, temporarily: delete it in step 4 |
| [Cutover](#public-access-through-cloudflare), step 4 | `www.1apx.com` | A | Your public IP | Cloudflare, **Proxied** | Yes: this is the name users open |

Notes:

- **`node.1apx.com`** isn't needed by the ORDS pods, which map it to `DB_IP` themselves, so they keep working when a node has switched to `8.8.8.8` (see [DNS](#dns)). Keep the record anyway: `deploy-ords.sh` warns when it and `DB_IP` disagree, which catches a database that has moved.
- **The node names** aren't needed by the cluster: every node has them in `/etc/hosts`. But the admin kubeconfig addresses the API server as `k8-control.1apx.com`, so a copy of it on another machine needs that record.
- **`www.1apx.com` already exists.** Before step 4 of the cutover, note its current records in Cloudflare (they may be `A`, `AAAA` or `CNAME`), so you can roll back. Then replace them with the single `A` record above, and **delete any `AAAA` or `CNAME` record for `www`**: if an old one stays, Cloudflare can still send part of the traffic to the old server. Cloudflare still answers IPv6 visitors, from its own addresses.
- **Proxied** (orange cloud) is what makes Cloudflare's protection and the [source-range rule](#public-access-through-cloudflare) work. A "DNS only" record would send users straight to your IP, where the Service refuses them.
- **If your public IP changes,** the two Cloudflare records must follow it (see [Public access through Cloudflare](#public-access-through-cloudflare)).

### The database

The Oracle database at `node.1apx.com` holds all the data and isn't part of this repo. The cluster's backups don't include it: its backups (RMAN or otherwise), patching and upgrades stay with whoever looks after the database (see [Ownership and contacts](#ownership-and-contacts)).

What the cluster needs from it:

| Need | Details |
|------|---------|
| Listener and service | Port 1521 on `node.1apx.com`, at `DB_IP` in `ords.env`, service `pdb1` |
| Network access | The database server's firewall must accept TCP 1521 from both workers, `192.168.1.171` and `192.168.1.172`. Pod traffic leaves the workers with the worker's own address |
| `ORDS_PUBLIC_USER` | Unlocked, with the password stored in the cluster (Step 7). Repeated wrong passwords lock it (`ORA-28000`) |
| ORDS schema | Installed, at the ORDS image's version (26.2.0, as installed today). ORDS here only serves: each pod's `db-check` step refuses to start against a schema of another version. The APEX version decides which images the pods download |
| Encryption | `SQLNET.ENCRYPTION_SERVER` and `SQLNET.CRYPTO_CHECKSUM_SERVER` in its `sqlnet.ora` must not be `rejected` (the default, `accepted`, is fine) |
| Sessions | Each ORDS pod keeps at least `jdbc.MinLimit` (25) sessions open and may open up to `jdbc.MaxLimit` (150), so two pods up to 300, plus the old server's while it runs. The database's `processes` and `sessions` limits must allow that |

**When the database is down or under maintenance,** every ORDS pod fails its readiness check, so the Service has no pod to send traffic to and Cloudflare shows its "origin unreachable" error page. ORDS recovers by itself when the database is back; nothing in the cluster needs restarting. Tell users before planned maintenance.

**The ORDS schema is installed and upgraded out of band.** ORDS in the cluster only serves (`ords serve`). Nothing in the cluster installs or upgrades the ORDS schema, and no SYS password is ever stored there. A DBA does it outside the cluster, after a database backup, with the `ords install` command of the target ORDS version (see Oracle's ORDS installation guide). The schema serves every ORDS server using the database, so in the same window, deploy the matching image ("ORDS upgrades" in [Running the cluster](#running-the-cluster)) and upgrade or retire the old server (see [C.7](#c7-retiring-the-old-ords-server)).

### Before you start

- **Existing database and ORDS.** ORDS in the cluster connects to the database your current ORDS server uses: `node.1apx.com:1521`, service `pdb1`, as `ORDS_PUBLIC_USER`. You need that user's existing password. The ORDS schema must already be installed there, at the image's version (26.2.0, as it is today): the cluster never installs or upgrades it (see [The database](#the-database)). The database server must accept the workers' connections; [The database](#the-database) lists everything the cluster needs from it.
- **Versions in the database.** The ORDS image version must match the ORDS version installed in the database, and the APEX images must match its APEX version. Step 7 checks both and tells you if anything needs changing.
- **Certificate.** Put the `*.1apx.com` files in `ssl/` at the top of this repo. `.gitignore` keeps that folder, and any `*.key`, `*.pem`, `*.p12`, `*.jks` and `*.pfx` file, out of git. Step 7 uses `ssl/1apx_com.crt`, `ssl/1apx_com.ca-bundle` and `ssl/1apx.key`. The certificate covers `*.1apx.com` and `1apx.com` and expires on **2 January 2027**.
- **Reserve the addresses** `192.168.1.171`, `192.168.1.172` and `192.168.1.180`–`192.168.1.189` on the router, or exclude them from its DHCP pool.
- **DNS records.** Add the "Before you start" rows of [DNS records to add](#dns-records-to-add): `node.1apx.com` (recommended), and optionally the node names. The Cloudflare records come later, at cutover.
- **CPU.** The ORDS image is built on Oracle Linux 10, which needs an x86-64-v3 CPU (AVX2: Intel Haswell or AMD Excavator, 2013, and later). The workers use the Proxmox host's own CPU type (`host`), and `proxmox-create-workers.sh` stops if the host's CPU lacks it. k8-control's virtual CPU doesn't need it, because ORDS never runs there.
- **Proxmox details.** The worker VMs' disks go on the ZFS storage `zfs-pool-data`, and their network on the bridge `vmbr0`. Check both on the Proxmox host with `pvesm status --content images` and `ip -br link`, and change `STORAGE` or `BRIDGE` in the script if yours differ. The script needs Proxmox VE 7.2 or later.
- **Password SSH to k8-control.** The VM script fetches `k8sadmin`'s public key by logging in to `<user>@192.168.1.170`, so the Proxmox host must be able to log in there with a password once.

In the steps below, run commands from the repo folder on k8-control, `/home/<user>/codebase/github/ubuntu`.

### Step 1: Create the admin account (on k8-control)

Script: [`k8s/scripts/create-admin-user.sh`](k8s/scripts/create-admin-user.sh). Run `sudo k8s/scripts/create-admin-user.sh`.

It creates `k8sadmin` with a locked password (SSH key login only), adds it to the `sudo` group, and gives it passwordless sudo through `/etc/sudoers.d/k8sadmin`, which `visudo` checks first. It also generates the account's own SSH key, `~k8sadmin/.ssh/id_ed25519`, which the next step installs on the workers.

### Step 2: Create the worker VMs (on the Proxmox host)

Script: [`k8s/scripts/proxmox-create-workers.sh`](k8s/scripts/proxmox-create-workers.sh). Copy it to the Proxmox host (for example with `scp` from k8-control) and run it there as root.

It fetches `k8sadmin`'s public key from k8-control, downloads the Ubuntu 26.04 cloud image, checks it against Ubuntu's published `SHA256SUMS`, and makes a template VM (ID 9000) from it. Then it creates full clones as VM 211 (`k8-worker-1`) and VM 212 (`k8-worker-2`), each with:

- 4 cores (CPU type `host`), 8 GB RAM with ballooning off, and a 60 GB disk on the ZFS storage `zfs-pool-data`. Kubernetes schedules by memory, so memory that can shrink causes problems. The disk has discard on, so space freed inside the VM is returned to the ZFS pool.
- A static IP, gateway `192.168.1.1`, DNS servers `192.168.1.1` and `8.8.8.8`, and search domain `1apx.com`, all set through cloud-init. This matches k8-control.
- The `k8sadmin` account with that SSH key and passwordless sudo. Cloud images don't allow SSH password logins.
- The QEMU guest agent enabled, and the VM set to start when the Proxmox host boots.

The script stops if a worker's IP already answers ping, or if the host's CPU can't run the ORDS image (see [Before you start](#before-you-start)).

Check: after a minute, on k8-control, `sudo -iu k8sadmin ssh 192.168.1.171 hostname` prints `k8-worker-1`.

### Step 3: Prepare k8-control

Script: [`k8s/scripts/node-prep.sh`](k8s/scripts/node-prep.sh). Run `sudo k8s/scripts/node-prep.sh` from the **Proxmox console**, because it turns on the firewall. Step 5 runs the same script on the workers for you.

It does what every Kubernetes node needs:

1. Adds the three nodes to `/etc/hosts`, and to cloud-init's template for it (`/etc/cloud/templates/hosts.debian.tmpl`). On the workers, cloud-init rewrites `/etc/hosts` from that template at every boot, so without this a worker would lose the names after a reboot and couldn't reach `k8-control.1apx.com`.
2. Checks that the DNS servers are `192.168.1.1` and `8.8.8.8` (see [DNS](#dns)).
3. Turns swap off. k8-control has a 4 GB swap file.
4. Loads the kernel modules and applies the kernel settings (see [Kernel settings](#kernel-settings)).
5. Installs containerd and sets it to systemd cgroups (the same as kubelet). It also sets containerd's pause image to the one kubeadm expects, `pause:3.10.2`.
6. Installs `kubelet`, `kubeadm` and `kubectl` 1.36.5 from `pkgs.k8s.io`, and holds them so `apt upgrade` can't change them.
7. Makes kubelet use the node's LAN IP, not the `127.0.1.1` entry Ubuntu puts in `/etc/hosts`.
8. Turns on the firewall (see [Firewall](#firewall)).

It ends with a summary. Check that swap shows 0, both modules are listed, `ip_forward` is 1, the firewall is active, and the machine ID is different on every node.

### Step 4: Create the control plane

Script: [`k8s/scripts/control-plane-init.sh`](k8s/scripts/control-plane-init.sh), which uses [`k8s/manifests/kubeadm-config.yaml`](k8s/manifests/kubeadm-config.yaml). Run `sudo k8s/scripts/control-plane-init.sh`.

1. Checks the kubeadm config, pulls the control-plane images and runs `kubeadm init`.
   The API server is reached as `k8-control.1apx.com:6443`.
   Before that, it sets up two things the API server needs from its first start:
   - **Encrypted Secrets.** Secrets, such as the database passwords and the TLS key, are encrypted in etcd, and so in etcd backups. The key is generated on k8-control into `/etc/kubernetes/enc/` and never leaves it, except in the etcd backups, which need it to restore.
   - **Audit log.** The API server logs every change to the cluster in `/var/log/kubernetes/audit/`, keeping 30 days. The policy is [`k8s/manifests/audit-policy.yaml`](k8s/manifests/audit-policy.yaml). For Secrets and ConfigMaps it logs who did what, never their contents. To change the policy later, copy it to `/etc/kubernetes/audit/policy.yaml` and restart the API server: move `/etc/kubernetes/manifests/kube-apiserver.yaml` out of that folder, wait until `sudo crictl ps --name kube-apiserver` lists nothing, then move it back.
2. Copies the admin kubeconfig to `~/.kube/config` for `<user>` and `k8sadmin`, so `kubectl` works for both.
3. Installs Calico with the pod network set to `10.244.0.0/16`, and waits until the node is `Ready`.

The control plane keeps its default taint, so ORDS and other workloads only run on the workers.

### Step 5: Join the workers

Script: [`k8s/scripts/join-workers.sh`](k8s/scripts/join-workers.sh). Run `sudo k8s/scripts/join-workers.sh`.

For each worker, it logs in as `k8sadmin` with that account's key, waits for cloud-init's first-boot work (including its package upgrade) to finish, then copies `node-prep.sh` there and runs it, including the firewall. Then it creates a join token that expires after 30 minutes, runs `kubeadm join` on the worker, and deletes the token. Finally it waits for both workers to be `Ready` and labels them as workers.

The first SSH connection to each worker saves its host key. If you want to check it, compare it with the key shown on the VM's Proxmox console.

Check: `kubectl get nodes -o wide` lists all three nodes as `Ready` with their `192.168.1.x` addresses.

### Step 6: Install the add-ons

Script: [`k8s/scripts/cluster-addons.sh`](k8s/scripts/cluster-addons.sh). Run `k8s/scripts/cluster-addons.sh` as `<user>`.

- **MetalLB** in layer-2 mode, with the pool `192.168.1.180`–`192.168.1.189` from [`k8s/manifests/addons/metallb-pool.yaml`](k8s/manifests/addons/metallb-pool.yaml). A `LoadBalancer` service gets one of these LAN IPs, and the worker running it answers ARP for it.
- **metrics-server**, so `kubectl top nodes` and `kubectl top pods` work. It skips verifying kubelets' self-signed serving certificates, which is the usual setting for kubeadm clusters.

### Step 7: Deploy ORDS

ORDS is deployed from its Kustomize overlay (see [Kustomize layout](#kustomize-layout)) by [`k8s/scripts/deploy-ords.sh`](k8s/scripts/deploy-ords.sh), which also creates the two Secrets that stay out of git.

**Before the first deploy:**

1. **The ORDS schema** must be installed in the database at the image's version, 26.2.0 (it is). ORDS here only serves: nothing in the cluster installs or upgrades the schema (see [The database](#the-database)).
2. **Production's values.** Check [`k8s/portal/prod/ords.env`](k8s/portal/prod/ords.env), which holds your current database details, and set **`DB_IP`** to the database server's IPv4 address. The pods reach the database only at that address, and map `node.1apx.com` to it themselves, so they don't depend on DNS for it. `ci/validate.sh` notes while it's empty, and `deploy-ords.sh` stops and shows what `node.1apx.com` resolves to.
3. Run `ci/validate.sh` and commit.

Then run `k8s/scripts/deploy-ords.sh` (the same as `deploy-ords.sh prod`) as `<user>`, in an interactive terminal: the first time, it asks for the `ORDS_PUBLIC_USER` password, and stops if it can't ask.

**ORDS settings.** [`k8s/portal/base/ords-settings.conf`](k8s/portal/base/ords-settings.conf) holds your existing server's `settings.xml` and `pool.xml` settings, one `key value` per line. The connection pool size, which depends on the number of pods, is in each environment's `ords-pool.conf` ([`prod/ords-pool.conf`](k8s/portal/prod/ords-pool.conf)). Every pod applies both when it starts. Changes from the old server:

- **Same:** context path `/apps`, APEX static files at `/i`, `plsql.gateway.mode direct` with `ords_util.authorize_plsql_gateway`, `misc.defaultPage apex`, `security.forceHTTPS true`, Database Actions and REST-enabled SQL off, and all the `jdbc.*` timeouts and limits.
- **Turned off:** the Database API (`database.api.enabled false`), which the old server had on but nothing uses, because ORDS is now on the internet. The MongoDB API is off by default and is also set off explicitly (`mongo.enabled false`).
- **Halved:** the connection pool, because there are now two ORDS pods. Each pod gets `InitialLimit 15`, `MinLimit 25` and `MaxLimit 150`, which add up to the old server's 30 / 50 / 300. To run a different number of pods, see [B.4](#b4-changing-the-number-of-ords-pods).
- **Port 8443** for HTTPS inside the pod, instead of 443, so ORDS runs without root. The service still listens on 443.
- **Encrypted database traffic.** Every connection to the database is encrypted and checksummed with Oracle Native Network Encryption (AES, SHA-2), or refused: ORDS and its `db-check` step both require it, through `DB_JAVA_OPTS` in the `ords-java` ConfigMap ([`base/kustomization.yaml`](k8s/portal/base/kustomization.yaml)). Databases allow it by default (`SQLNET.ENCRYPTION_SERVER = accepted`), so nothing changes on the database server, unless it's set to `rejected` (see [B.3](#b3-troubleshooting), `ORA-12660`).
- **Left out:** `standalone.use.https` and `standalone.use.ssl.cert` (old settings, unused by current ORDS), the old server's access log path (`standalone.access.log`), the empty `misc.compress`, and the `default` → `plsql.gateway.mode` line, which isn't a real setting.

**What the script does:**

1. **Checks the environment's values:** `DB_IP` must be set, and it warns if `node.1apx.com` resolves to a different address.
2. **Namespace.** Creates `ords` from the build: `common`'s namespace, which enforces Pod Security `restricted`. The API server refuses any pod there that could run as root, keep Linux capabilities, or use a host folder.
3. **Certificate.** Checks that it covers `www.1apx.com` and hasn't expired, and warns 30 days before expiry. Checks that the key matches. Joins the certificate and intermediates into one chain, converts the key to PKCS#8, and stores both as the `ords-tls` Secret.
4. **ORDS_PUBLIC_USER password.** The first time, asks for it twice, without echoing or saving it, and stores it as a Secret.
5. **Applies the overlay,** `kubectl kustomize k8s/portal/prod`:
   - **Network policies.** `common`'s policy blocks everything except DNS, and ORDS's adds only what it needs: in, HTTPS on 8443; out, the database at `DB_IP` on port 1521, and HTTPS (443, for the APEX images download).
   - **The ORDS objects:** the ConfigMaps, Deployment, Service and PodDisruptionBudget.
   - **Replacing the pods.** A changed setting gives its ConfigMap a new name, which replaces the pods one at a time. If only a Secret changed (a renewed certificate), the script replaces the pods itself.
6. **Waits for the rollout,** up to 15 minutes. If it doesn't finish, it shows each new pod's `db-check` log and stops; the old pods keep serving meanwhile.
7. **Cleans up** generated ConfigMaps that neither this build nor a ReplicaSet kept for `kubectl rollout undo` uses.
8. **Tests** `/` and `/apps/` directly at `192.168.1.180`, bypassing Cloudflare and DNS.

**Each ORDS pod, when it starts:**

1. **`db-check`** logs in to `node.1apx.com:1521/pdb1` as `ORDS_PUBLIC_USER`, which proves the network path, the password and that the database accepts encryption. It then compares the database's ORDS schema version with the image's. If they differ, it stops: the pod never becomes ready, and during a rollout the old pods keep serving. It also records the database's APEX version, or `APEX_VERSION` from `ords.env` if that's set.
2. **`apex-images`** downloads the images for that APEX version (about 290 MB, 480 MB unpacked) into the pod's own temporary volume (`emptyDir`), which adds a minute or so to a pod's start. The workers need HTTPS access to `download.oracle.com`.
3. **`config`** writes the pod's ORDS configuration: the database, the settings files, the certificate, the APEX images, the redirect page for `/`, the access log, and the password, into ORDS's wallet.
4. **ORDS** starts, with its `access-log` sidecar.

The first pod on each worker also downloads the ORDS image (about 700 MB).

**The deployment:**

- **Two replicas** (`replicas:` in `prod/kustomization.yaml`), normally one on each worker, with a PodDisruptionBudget so node maintenance takes down only one at a time. The spread is a preference, so both replicas can run on one worker while the other is drained or down.
- **No shared storage.** Each pod writes its own ORDS config when it starts. There's no SYS password anywhere in the cluster.
- **Serve only.** The ORDS container runs `ords serve` directly, which never installs or upgrades the schema. The image's entrypoint would install it when given a SYS password, and turn on Database Actions, REST-enabled SQL and the MongoDB API at every start, overriding your settings.
- **Locked down:** every container runs as the image's `oracle` user (UID 54321), never as root, with no Linux capabilities, no Kubernetes API token, a read-only root filesystem, and memory limits (3 GiB for ORDS). They write only to their own temporary volumes: ORDS's config, the APEX images and `/tmp`.
- **Health checks** connect over HTTPS and send `Host: www.1apx.com`, because ORDS rejects HTTPS requests whose host doesn't match the certificate. Readiness uses `/apps/_/landing`, which fails (`571`) when ORDS can't reach the database, so traffic only goes to pods with a working connection.
- **Service** on `192.168.1.180`: port **443**, HTTPS only (Cloudflare redirects `http://` to `https://` before traffic reaches the cluster). It accepts connections only from Cloudflare's addresses and the cluster's nodes (see [Public access through Cloudflare](#public-access-through-cloudflare)). It doesn't allocate NodePorts, because MetalLB answers on the LAN IP directly.
- **Root redirect:** `https://www.1apx.com/` (no path) shows a small page in each pod that sends the browser on to `/apps/`.
- **Image pinned by digest** (`images:` in `prod/kustomization.yaml`, `26.2.0@sha256:...`), so the image can't change even if Oracle re-publishes the tag. The manifests were tested on the 26.2.0 and 26.2.3 images (their `ords` commands, user and file layout); recent versions share them, but check an older one before using it, because older images differ.

After cutover, users open **`https://www.1apx.com/`**, which leads to `https://www.1apx.com/apps/`. APEX is at `https://www.1apx.com/apps/r/...` (or `/apps/f?p=...`), the same paths as on the old server.

To change a setting, edit `ords-settings.conf` (or `ords-pool.conf`), run `ci/validate.sh`, commit, and run the script again. `deploy-ords.sh --diff` shows the change first. The pods are replaced one at a time, and only if something changed.

### Step 8: Check the cluster

On k8-control, as `<user>`:

- `kubectl get nodes -o wide` shows three `Ready` nodes.
- `kubectl get pods -A` shows everything `Running`.
- `kubectl get pods -n ords -o wide` shows one ORDS pod on each worker, both `1/1 Ready`. If both are on one worker (after that worker was down, for example), run `kubectl rollout restart deployment/ords -n ords` to spread them again. A pod stays `0/1` while it can't reach the database.
- `kubectl logs -n ords deploy/ords` shows "HTTPS listening on host: 0.0.0.0 port: 8443" and no pool errors.
- `curl -sI --resolve www.1apx.com:443:192.168.1.180 https://www.1apx.com/apps/` returns a `302` to the APEX start page, straight from the cluster (before cutover, DNS still points `www` elsewhere). The same for `/` returns `200`, the redirect page. Running `curl -vI` also shows the `*.1apx.com` certificate.
- After cutover, `curl -sI https://www.1apx.com/apps/` from outside the LAN shows `server: cloudflare` and the same `302`.
- **Cloudflare can't be bypassed.** From a machine outside your network (a laptop on a phone's hotspot, for example), connect straight to your public IP: `curl -skI --max-time 15 --resolve www.1apx.com:443:<your public IP> https://www.1apx.com/apps/`. It must fail with a timeout: the Service drops connections from addresses that aren't Cloudflare's. If it answers, anyone can reach ORDS without Cloudflare's protection: check `loadBalancerSourceRanges` in `ords.yaml` and whether the router rewrites the source address of forwarded connections. Your public IP is in the router's status page, or `curl -s https://ifconfig.me` from the LAN.
- `sudo k8s/scripts/health-check.sh` reports every check as `ok` (see [C.2](#c2-monitoring-and-alerts) to run it every 15 minutes, with alerts).
- `kubectl top nodes` shows CPU and memory for each node.
- Secrets are encrypted in etcd: `sudo crictl exec $(sudo crictl ps --name '^etcd$' -q) etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/ords/ords-tls | head -c 80 | od -c | head -3` shows `k8s:enc:secretbox:v1:key1`, not the certificate.
- `sudo tail -1 /var/log/kubernetes/audit/audit.log` shows a recent API request.

### Running the cluster

- **Backups.** Script: [`k8s/scripts/etcd-backup.sh`](k8s/scripts/etcd-backup.sh). Run `sudo k8s/scripts/etcd-backup.sh` on k8-control. It saves an etcd snapshot (the whole cluster state) plus `/etc/kubernetes` (certificates and config), kubelet's credentials, `k8sadmin`'s SSH key and the matching `etcdutl` to `/var/backups/kubernetes`, and keeps 14 days. To run it daily, copy it to `/usr/local/sbin` and add a cron line; the script's header shows both commands. Re-run the `install` command after changing the script. Copy the backups off the VM, and keep them private: they contain the cluster's private keys and the key that decrypts its Secrets. Also set up scheduled Proxmox backups (vzdump) of all three VMs. To restore, see [C.4](#c4-backups-and-restore).
- **Health checks and alerts.** Script: [`k8s/scripts/health-check.sh`](k8s/scripts/health-check.sh). It checks the nodes, ORDS, certificates, disk space and backups; schedule it and connect it to an alerting service as in [C.2](#c2-monitoring-and-alerts).
- **Certificates** that kubeadm creates expire after one year, and upgrading the control plane renews them. Check them with `sudo kubeadm certs check-expiration`.
- **Upgrades.** Move up one minor version at a time (1.36 → 1.37), control plane first, then each worker. Drain each worker with `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` first (the ORDS pods keep their generated config in an `emptyDir`, which drain otherwise refuses to delete); the ORDS PodDisruptionBudget keeps one replica up. Change `K8S_MINOR` and `K8S_VERSION` in `node-prep.sh`, the version in `kubeadm-config.yaml` and the `pod-security.kubernetes.io/*-version` labels in `k8s/common/namespace.yaml`, and upgrade Calico when its tested versions require it. When you change Calico's, MetalLB's or metrics-server's version, update its lines in `k8s/config/upstream.sha256` too (the file's header shows how). The commands are in [C.5](#c5-upgrades-step-by-step).
- **OS updates.** `apt upgrade` is safe because the Kubernetes packages are held. Reboot one node at a time, draining workers first (see Maintenance in [B.2](#b2-day-to-day-operations)).
- **Certificate renewal.** The `*.1apx.com` certificate expires on 2 January 2027. Put the renewed files in `ssl/` with the same names, or change `CERT_FILE`, `CHAIN_FILE` and `KEY_FILE`. Then run `deploy-ords.sh` again, which updates the `ords-tls` Secret and restarts the pods one at a time.
- **ORDS upgrades,** in one maintenance window. First a DBA upgrades the ORDS schema, out of band (see [The database](#the-database)). Then set `newTag` and `digest` under `images:` in `k8s/portal/prod/kustomization.yaml` to the new version (the comment above them says where to find the digest), run `ci/validate.sh`, commit, and run `deploy-ords.sh`. Until then, new pods refuse to start (their `db-check` sees the newer schema), and whether the running ones keep working with it depends on the versions: check ORDS's release notes. Upgrade the old ORDS server too, or retire it.
- **Secrets.** Never commit passwords or keys to this repo; `ssl/` is git-ignored. To change the `ORDS_PUBLIC_USER` password, change it in the database, run `kubectl delete secret ords-db-runtime -n ords`, then run `deploy-ords.sh` again. The old ORDS server needs the new password too.
- **Single control plane.** If k8-control is down, running ORDS pods keep serving, but you can't change the cluster until it's back. For high availability, add two more control-plane nodes behind `k8-control.1apx.com`, and restore from the etcd backups if needed.
- **Starting over on a node.** `sudo kubeadm reset` removes Kubernetes state from a node. On the control plane, that deletes the cluster.

For the security measures in place, day-to-day commands and a troubleshooting guide for ORDS, see [Appendix B](#appendix-b-ords-on-kubernetes-security-operations-and-troubleshooting).

## Validation and CI

[`ci/validate.sh`](ci/validate.sh) checks the whole repo. Run it before every commit, as `<user>`: `ci/validate.sh`, or `ci/validate.sh --offline` without internet access (after one online run, which fills its cache). It exits non-zero if any check fails. GitHub Actions runs it on every push and pull request, and every Monday, because its online checks (Cloudflare's ranges, the pinned upstream files) can start failing with no change in the repo ([`.github/workflows/validate.yml`](.github/workflows/validate.yml)).

| Area | What it checks |
|------|----------------|
| Shell scripts | `bash -n` and ShellCheck on every script; every script is executable in git |
| Kubernetes | Every portal environment built with the cluster's own `kubectl` (Kustomize), exactly as `deploy-ords.sh` builds it, with no placeholder left, against the Kubernetes schemas for the cluster's version with kubeconform `-strict`. `dev` and `uat` are checked to be placeholders until they're set up. Also and the MetalLB pool against MetalLB's CRD schemas (from a pinned commit of the CRDs catalog). The kubeadm config with the real `kubeadm` of the same version. The audit policy's shape. Every pod against the Pod Security `restricted` rules the namespace enforces, and a read-only root filesystem on every container. `bash -n` on the scripts inside the manifests |
| Consistency | Values repeated across files agree: Kubernetes version (including the namespace's Pod Security version), pod CIDR, node IPs, DNS servers, the personal login, the encryption config path, and, per environment, its MetalLB address inside the pool and not shared, its database port the same in `ords.env` and the network policy, and every image pinned by tag and digest |
| Upstream | Every manifest the scripts download is pinned in `upstream.sha256` (and nothing else is). Online: each pin still matches upstream, the scripts' edits to Calico's and metrics-server's files still apply, and Calico's Installation with our pod CIDR is valid |
| Documentation | Every relative link and `#anchor` in the README resolves, and [Contents](#contents) lists every section and subsection, in order. `docs/architecture.svg` is exactly what `docs/architecture.py` generates, so the diagram can't drift from its source, and the generator's own checks pass (labels fit their boxes, no arrow crosses a label, no text under 14 px) |
| Hygiene | LF line endings, no trailing whitespace, a final newline in every file |
| Secrets | gitleaks over the files staged for the next commit and the whole git history; no key, certificate or kubeconfig file tracked |

The tools (ShellCheck, kubeconform, kubeadm, kubectl, gitleaks, and the Arimo font the diagram is measured with) are downloaded on first use, checked against pinned SHA-256s, and cached in `~/.cache/ubuntu-repo-tools`. The script also needs Python's yaml module (`python3-yaml`, installed on k8-control).

Repo conventions: [`.gitattributes`](.gitattributes) stores text files with LF line endings, [`.editorconfig`](.editorconfig) sets the same for editors, and [`.gitignore`](.gitignore) keeps keys, certificates, kubeconfigs and etcd backups out of git.

[`.github/dependabot.yml`](.github/dependabot.yml) has Dependabot propose a pull request each week when the GitHub Action the workflow uses, pinned by commit, has a new release.

**On github.com** (needs the account's owner): under **Settings → Branches**, add a rule for `main` that requires the `validate` check to pass, so nothing unchecked lands on `main`.

## GitHub access

This repo is pushed from k8-control to the private repo [`1apx-codebase/ubuntu`](https://github.com/1apx-codebase/ubuntu) over SSH.
Run every command as `<user>`, not root, so the key and repo stay owned by that user.

| Item | Value |
|------|-------|
| Local repo | `/home/<user>/codebase/github/ubuntu` |
| Remote | `origin` → `git@github.com:1apx-codebase/ubuntu.git` |
| Branch | `main`, tracking `origin/main` |
| SSH key | `~/.ssh/id_ed25519` (ed25519, no passphrase), added to the `1apx-codebase` GitHub account |
| Key fingerprint | `SHA256:KvkjMyF+FAECb2T15hknyvUzrue/6Hrq3KNxAjiQbo8` |
| Commit identity | Set for this repo only: `Virgil Aviles <virgil.aviles@proton.me>` |

### One-time setup

Script: [`setup-github.sh`](setup-github.sh). Run it as `<user>` with `./setup-github.sh`, not with sudo.

The script:

1. Creates `~/.ssh/id_ed25519` if it doesn't exist.
2. Checks that GitHub accepts the key. If it doesn't, the script prints the public key, saves a copy to `~/github-ssh-key.txt` (with an `scp` command to fetch it from another computer) and waits until you've added it on GitHub. It deletes the copy afterwards.
3. Sets up the local repo and the commit name and email for this repo.
4. Points `origin` at `git@github.com:1apx-codebase/ubuntu.git`.
5. Checks the GitHub repo exists. If it doesn't, the script waits while you create it as an empty, private repo.
6. Pushes `main`, then reports whether the repo is private.

Two steps happen on github.com: adding the key under **Settings → SSH and GPG keys**, and creating the repo. To use a different account, repo, name or email, edit the variables at the top of the script.

## Ownership, changes and licensing

### Ownership and contacts

Fill this in and keep it current; whoever looks after the cluster next starts here. Keep passwords out of it ([C.1](#c1-credentials-and-where-they-live) says where they live).

| Area | Owner | Contact | Notes |
|------|-------|---------|-------|
| This cluster (k8-control, workers) and this repo | `<user>` | | |
| Oracle database `node.1apx.com`, its backups and ORDS schema | | | |
| Domain `1apx.com` and the Cloudflare account | | | Includes the `*.1apx.com` certificate renewal |
| Router (port forward, DHCP reservations, DNS records) | | | |
| Proxmox host(s) and their backups | | | |
| GitHub organisation `1apx-codebase` | | | |
| Old ORDS server, until retired | | | See [C.7](#c7-retiring-the-old-ords-server) |
| Escalation when the site is down | | | |

### Change history

[`CHANGELOG.md`](CHANGELOG.md) summarises significant changes: what changed for the cluster or its users, and why. Add an entry with each change that matters to someone running the cluster; `git log` keeps the details.

### Licensing

| Component | Licence |
|-----------|---------|
| ORDS (the container image's `/opt/oracle/ords`) | Oracle Free Use Terms and Conditions (the image's `/opt/oracle/ords/LICENSE.txt`) |
| Java in the ORDS image (Oracle GraalVM) | GraalVM Free Terms and Conditions |
| Oracle Linux, the image's base | Free to use; its packages carry their own open-source licences |
| APEX | A no-cost feature of the Oracle Database; the database itself needs its own licence, which this setup doesn't change |
| Kubernetes, containerd, Calico, MetalLB, metrics-server | Apache License 2.0 |
| Ubuntu | Free; its packages carry their own open-source licences |
| Tools used only by `ci/validate.sh` | ShellCheck (GPL-3.0), kubeconform (Apache 2.0), gitleaks (MIT), the Arimo font (SIL Open Font License 1.1; only its measurements are read) |

Running these as described here is within their terms. Read Oracle's terms before redistributing the ORDS image or using it for anything else. This repo is private and has no licence file: its contents stay with its owner.

## Appendix A: Copying text from Claude Code

On 2026-10-15, text couldn't be copied out of Claude Code (run as `sudo claude`) with the mouse.

**Cause.** A fresh install of Claude Code starts in its fullscreen interface, which captures the mouse. Dragging selects text inside Claude Code, which then tries to copy it to the clipboard with an OSC 52 escape code. The terminal used here doesn't accept OSC 52, so nothing reached the clipboard. Pasting into Claude Code was not affected.

**Fix.** Switch Claude Code to its classic interface, so the terminal handles selection and copy itself:

| Change | File | Used by |
|--------|------|---------|
| Add `"tui": "default"` | `/root/.claude/settings.json` | `sudo claude` |
| Add `"tui": "default"` | `/home/<user>/.claude/settings.json` | `claude` as `<user>` |

Both files now read:

```json
{
  "theme": "auto",
  "tui": "default"
}
```

The originals are backed up at `/root/.claude/settings.json.bak-2026-10-15-015041` and `/home/<user>/.claude/settings.json.bak-2026-10-15-015744`.

Script: [`claude-classic-tui.sh`](claude-classic-tui.sh). Run it with `sudo ./claude-classic-tui.sh`, or `sudo ./claude-classic-tui.sh --revert` to go back to fullscreen. It changes both files, backs each one up first, and keeps each file's owner.

Notes:

- **Restart Claude Code after the change.** If the setting changes while a session is running, the screen can go blank. Press Ctrl+L to redraw, or exit and run `sudo claude` again, then use `/resume` to continue the conversation.
- **Settings are per user.** `sudo claude` reads `/root/.claude/settings.json`, and `claude` as `<user>` reads `/home/<user>/.claude/settings.json`, so both need the setting. To cover another user, add them to `TARGETS` at the top of the script.
- **Without this fix**, you can still copy in the fullscreen interface by holding a key while you drag: Shift in most Linux and Windows terminals and PuTTY, Option in iTerm2, Fn in macOS Terminal.app.

## Appendix B: ORDS on Kubernetes: security, operations and troubleshooting

Commands run on k8-control as `<user>` unless marked `sudo`. ORDS lives in the `ords` namespace, so most commands need `-n ords`.

### B.1 Security practices applied

**Nodes**

| Practice | Where |
|----------|-------|
| A dedicated admin account, `k8sadmin`, with SSH key login only (no password), separate from personal accounts | `create-admin-user.sh`, `proxmox-create-workers.sh` |
| Host firewall (ufw) denies incoming traffic by default and opens only the cluster's ports, each to the nodes or the LAN that need it. etcd, the scheduler and the controller manager aren't reachable from the network | `node-prep.sh` (see [Firewall](#firewall)) |
| Worker VMs come from Ubuntu's cloud image, checked against Ubuntu's published SHA-256, with their own machine ID and SSH host keys | `proxmox-create-workers.sh` |
| Kubernetes packages pinned to one version and held, so `apt upgrade` can't change them | `node-prep.sh` |
| Join tokens expire after 30 minutes and are deleted as soon as the worker has joined | `join-workers.sh` |

**Cluster**

| Practice | Where |
|----------|-------|
| Secrets are encrypted at rest in etcd (secretbox), so database passwords and the TLS key aren't readable in etcd or its backups. The key is generated on k8-control and never stored in git | `control-plane-init.sh`, `kubeadm-config.yaml` |
| API audit log of every change, kept 30 days. Secrets and ConfigMaps are logged as "who did what", never with their contents | `audit-policy.yaml` |
| kubeadm's defaults: RBAC, TLS between every component, and an admin kubeconfig bound to the `kubeadm:cluster-admins` group rather than the unrevokable `system:masters` | `kubeadm init` |
| The control plane keeps its taint, so ORDS never runs next to etcd and the API server | `kubeadm-config.yaml` |
| Every upstream manifest (Calico, MetalLB, metrics-server) is checked against a SHA-256 pinned in the repo before it's applied | `common.sh`, `k8s/config/upstream.sha256` |
| etcd backups are root-only (`0700` folder, `0600` files), and cron runs a root-owned copy of the script, not the one in a user's home | `etcd-backup.sh` |

**ORDS namespace and network**

| Practice | Where |
|----------|-------|
| Its own namespace, `ords`, so its network policies, Secrets and permissions apply to ORDS alone | `k8s/common/namespace.yaml`, `k8s/portal/prod/kustomization.yaml` |
| Network policies block everything not listed. The namespace's default allows only DNS (CoreDNS); ORDS's adds, in: only its HTTPS port, 8443; out: the database's own address on its port, and HTTPS | `k8s/common/network-policy.yaml`, `k8s/portal/base/network-policy.yaml` |
| The Service allocates no NodePorts; ORDS is reachable only on its MetalLB address, `192.168.1.180` | `service.yaml` |
| From the internet, ORDS is reachable only through Cloudflare: the Service admits only Cloudflare's address ranges and the three nodes (`loadBalancerSourceRanges`), not the whole LAN, in case the router rewrites forwarded connections' source, so Cloudflare's DDoS and bot protection can't be bypassed. `ci/validate.sh` checks the ranges against Cloudflare's published list | `service.yaml`, `ci/validate.sh` |
| HTTPS all the way: browsers to Cloudflare, and Cloudflare to ORDS with the certificate checked (SSL mode Full (strict)) | Cloudflare (see [Public access](#public-access-through-cloudflare)) |
| HTTPS only: the Service and network policy admit only HTTPS, Cloudflare redirects `http://` to `https://`, and ORDS serves the full certificate chain | `service.yaml`, `network-policy.yaml`, `deploy-ords.sh` |
| Database traffic is encrypted (AES) and checksummed (SHA-2), required by ORDS and its `db-check` step, so a connection that can't be encrypted is refused | `k8s/portal/base/kustomization.yaml` (`ords-java`) |

**ORDS pods**

| Practice | Where |
|----------|-------|
| Pod Security `restricted` is enforced on the namespace, so the API server refuses any pod that breaks it. `ci/validate.sh` checks every environment's pods against the same rules | `k8s/common/namespace.yaml`, `ci/validate.sh` |
| ORDS only serves: nothing in the cluster installs or upgrades the ORDS schema, and its `db-check` step refuses to start against a schema of another version instead | `deployment.yaml` |
| Every container runs as the image's `oracle` user (UID 54321), never root, with no Linux capabilities, no privilege escalation, and the default seccomp profile | `deployment.yaml` |
| Every container's root filesystem is read-only; each writes only to its own `emptyDir` volumes (config, APEX images, `/tmp`), each with a size limit | `deployment.yaml` |
| No Kubernetes API token in the pods (`automountServiceAccountToken: false`); ORDS never talks to the API | `deployment.yaml` |
| Memory limits on every container, so a leak can't take a worker down | `deployment.yaml` |
| Image pinned by digest, so it can't change even if Oracle re-publishes the tag | `k8s/portal/prod/kustomization.yaml` |
| Only APEX and the PL/SQL gateway are served: the Database API, Database Actions, REST-enabled SQL and the MongoDB API are all off. ORDS is started directly (`ords serve`), because the image's entrypoint would switch the last three back on | `deployment.yaml`, `ords-settings.conf` |
| PL/SQL gateway calls go through `ords_util.authorize_plsql_gateway`, which allows only procedures that are explicitly permitted | `ords-settings.conf` |

**Secrets handling**

| Practice | Where |
|----------|-------|
| Passwords are typed at a prompt that doesn't echo them, never passed on a command line, and only briefly written to a private (`0700`) temporary folder | `deploy-ords.sh` |
| Secrets are applied server-side, so no second copy of their values is kept in a `last-applied-configuration` annotation | `deploy-ords.sh` |
| There's no SYS password in the cluster: ORDS only serves, and the schema is installed and upgraded out of band | `deployment.yaml`, `deploy-ords.sh` |
| The `ORDS_PUBLIC_USER` password Secret is mounted only into the init container that writes ORDS's config, where it goes into ORDS's encrypted wallet. The ORDS container itself never mounts it | `deployment.yaml` |
| The TLS key is readable only by the pod's group (`0440`) | `deployment.yaml` |
| No keys, certificates, kubeconfigs or passwords in git: `.gitignore` excludes them, and gitleaks scans the files staged for commit and the whole history | `.gitignore`, `ci/validate.sh` |

**Known gaps (accepted or still open)**

| Gap | Why, and what would close it |
|-----|------------------------------|
| HTTPS out of the namespace is allowed to any address | Needed for the APEX images download from `download.oracle.com`, whose addresses change |
| Other ORDS servers using the same database (such as the old one) aren't covered by the cluster's encryption setting | Their traffic is encrypted only if they ask for it too, or if the database requires it for everyone: `SQLNET.ENCRYPTION_SERVER = required` and `SQLNET.CRYPTO_CHECKSUM_SERVER = required` in its `sqlnet.ora` |
| ORDS is exposed to the internet through a router port forward | Chosen over a Cloudflare Tunnel. The source ranges limit it to Cloudflare. A tunnel (`cloudflared`) would need no open port at all |
| ORDS doesn't verify that a connection really comes through your Cloudflare account | Anyone's Cloudflare-proxied site could point at your IP. Cloudflare's Authenticated Origin Pulls would close this, but need client-certificate checking in front of ORDS |
| metrics-server doesn't verify kubelets' certificates | The usual kubeadm setting. Verifying them means approving kubelet certificates by hand every year |
| `<user>` and `k8sadmin` have passwordless sudo | Chosen for automation (see the top of this README) |
| One control-plane node | See [Running the cluster](#running-the-cluster) |

### B.2 Day-to-day operations

**Check health**

| Task | Command |
|------|---------|
| Pods, which worker each is on, and readiness | `kubectl get pods -n ords -o wide` |
| Service and its LAN IP | `kubectl get svc -n ords` |
| CPU and memory use | `kubectl top pods -n ords` |
| Recent events (scheduling, probes, restarts) | `kubectl get events -n ords --sort-by=.lastTimestamp` |
| Directly, on k8-control | `curl -sI --resolve www.1apx.com:443:192.168.1.180 https://www.1apx.com/apps/` returns `302` |
| Everything at once (nodes, ORDS, certificates, disks, backups) | `sudo k8s/scripts/health-check.sh` |
| Through Cloudflare | `curl -sI https://www.1apx.com/apps/` returns `302` (`403` with `cf-mitigated: challenge` means Cloudflare's bot check stopped curl; a browser passes it) |
| Cloudflare's address ranges changed | `ci/validate.sh` says so. Update `loadBalancerSourceRanges` in `k8s/portal/base/service.yaml` from <https://www.cloudflare.com/ips-v4>, commit, and run `deploy-ords.sh` |

**Logs**

| Task | Command |
|------|---------|
| ORDS log of one pod | `kubectl logs -n ords <pod>` (or `deploy/ords` for any one pod) |
| Follow both pods | `kubectl logs -n ords -l app=ords -f --prefix` |
| Every request (access log) | `kubectl logs -n ords -l app=ords -c access-log --prefix` (see [C.3](#c3-access-logs)) |
| A pod's previous run, after a restart | `kubectl logs -n ords <pod> --previous` |
| Startup steps (APEX download, config) | `kubectl logs -n ords <pod> -c apex-images` and `-c config` |
| Who changed what in the namespace | `sudo jq -r 'select(.objectRef.namespace=="ords" and .verb!="get" and .verb!="list" and .verb!="watch") \| [.requestReceivedTimestamp, .user.username, .verb, .objectRef.resource, .objectRef.name] \| @tsv' /var/log/kubernetes/audit/audit.log \| tail -20` |

**Change things**

| Task | How |
|------|-----|
| Change an ORDS setting | Edit `k8s/portal/base/ords-settings.conf` (or the environment's `ords-pool.conf`), run `ci/validate.sh`, commit, then run `k8s/scripts/deploy-ords.sh`. The changed settings get a new ConfigMap name, so the pods are replaced one at a time. `--diff` shows the change first |
| Restart ORDS (no change) | `kubectl rollout restart deployment/ords -n ords`, then `kubectl rollout status deployment/ords -n ords` |
| Undo the last rollout | `kubectl rollout undo deployment/ords -n ords` |
| See the settings a pod is running with | `kubectl exec -n ords deploy/ords -- ords --config /etc/ords/config config list` |
| Change the `ORDS_PUBLIC_USER` password | Change it in the database, then `kubectl delete secret ords-db-runtime -n ords` and run `deploy-ords.sh`, which asks for the new one. Update the old ORDS server too |
| Renew the certificate | Put the new files in `ssl/` with the same names and run `deploy-ords.sh`. Check the expiry date in use with `kubectl get secret ords-tls -n ords -o jsonpath='{.data.tls\.crt}' \| base64 -d \| openssl x509 -noout -enddate` |
| Upgrade ORDS | See "ORDS upgrades" under [Running the cluster](#running-the-cluster). Tag and digest both change |
| New APEX version in the database | Run `deploy-ords.sh`. It finds the new version, and the pods it replaces download the new images when they start |
| More or fewer ORDS pods | See [B.4](#b4-changing-the-number-of-ords-pods) |

**Maintenance**

| Task | How |
|------|-----|
| Take a worker down (patching, reboot) | `kubectl drain k8-worker-1 --ignore-daemonsets --delete-emptydir-data`, do the work, then `kubectl uncordon k8-worker-1`. The PodDisruptionBudget lets only one ORDS pod go down at a time, and the other worker takes both while this one is out. Then `kubectl rollout restart deployment/ords -n ords` to spread them again |
| Back up the cluster | `sudo k8s/scripts/etcd-backup.sh`, or check that the daily cron ran: `sudo ls -lt /var/backups/kubernetes \| head` |
| Cluster certificates | `sudo kubeadm certs check-expiration` once a month. They expire after a year unless the control plane is upgraded |
| Before any commit | `ci/validate.sh` |
| See what a deploy would change | `k8s/scripts/deploy-ords.sh --diff` (see [C.6](#c6-testing-changes)) |

### B.3 Troubleshooting

Start with `kubectl get pods -n ords -o wide` and `kubectl describe pod -n ords <pod>`. The `Events` at the bottom of `describe` usually name the problem.

**Pods don't start**

| Symptom | Likely cause | Check and fix |
|---------|--------------|---------------|
| `Pending` | Not enough CPU or memory on the workers, or both workers unschedulable | `describe` shows `Insufficient memory` or `node(s) were unschedulable`. Free up resources, or `kubectl uncordon` the worker |
| No pod is created; `kubectl get events -n ords` shows `violates PodSecurity "restricted"` | A manifest change broke a `restricted` rule | The event names the rule. Fix the manifest; `ci/validate.sh` checks the same rules before you deploy |
| `CrashLoopBackOff`, log says `Fatal glibc error: CPU does not support x86-64-v3` | The worker's virtual CPU lacks AVX2 | In Proxmox, set the VM's CPU type to `host` (or `x86-64-v3`) on a host whose CPU has it, then restart the VM |
| `ErrImagePull` or `ImagePullBackOff` | The worker can't reach `container-registry.oracle.com`, or the tag and digest under `images:` in the environment's `kustomization.yaml` don't match | `describe` shows the registry's error. From the worker: `curl -sI https://container-registry.oracle.com`. Check the digest belongs to the tag |
| `Init:Error` or `Init:CrashLoopBackOff` | A start-up step failed: the database check, the APEX download or the config step | `kubectl logs -n ords <pod> -c db-check` (see "The database check fails" below), `-c apex-images` (download blocked, or no `apex_<version>.zip`), and `-c config` (often a misspelt key in `ords-settings.conf`) |
| Pod `Evicted`, message mentions `ephemeral local storage usage exceeds` | A temporary volume outgrew its size limit (`sizeLimit` in `deployment.yaml`), for example because a new APEX version's images are larger | Raise that volume's `sizeLimit` and redeploy |
| `CrashLoopBackOff`, `describe` shows `Last State: OOMKilled` | ORDS needs more memory than its 3 GiB limit | Raise `limits.memory` in `k8s/portal/base/deployment.yaml` and redeploy |
| `CrashLoopBackOff`, log mentions the certificate or key | The TLS key isn't PKCS#8, or doesn't match the certificate | Re-run `deploy-ords.sh`, which converts and checks it |

**Pods run but aren't Ready (`0/1`)**

Readiness uses `/apps/_/landing`, which returns `571` when ORDS can't reach the database. So `0/1` almost always means a database problem. `kubectl logs -n ords <pod>` shows the pool error:

| Error in the log | Meaning | Fix |
|------------------|---------|-----|
| `ORA-01017` | Wrong `ORDS_PUBLIC_USER` password | Replace the Secret (see B.2) |
| `ORA-28000` | The account is locked, often after repeated wrong passwords | Unlock it in the database, then fix the password |
| `ORA-12514` | The listener doesn't know the service `pdb1` | Check `DB_SERVICE` in `deploy-ords.sh` against `lsnrctl status` on the database server |
| `ORA-12541`, connect timeout, `IO Error` | No network path to `node.1apx.com:1521` | Check the database's firewall allows the workers' IPs (171, 172), and that `DB_IP` in `ords.env` is the database's address: the pods reach only that address. If the database moved, change `DB_IP`, commit and run `deploy-ords.sh` |
| `UnknownHostException` | The pods can't resolve the database name | They map `DB_HOST` to `DB_IP` themselves, so check both in `ords.env`, and `kubectl exec -n ords deploy/ords -- cat /etc/hosts` |
| `ORA-12660` | The database refuses encryption (`SQLNET.ENCRYPTION_SERVER = rejected` in its `sqlnet.ora`) | Change that to `accepted` or `required` on the database server. Only if that isn't possible, turn it off for that environment: in its `kustomization.yaml`, add a `configMapGenerator` entry `name: ords-java`, `behavior: merge`, `literals: [DB_JAVA_OPTS=]`, and redeploy |

**The database check fails** (pods stay in `Init:CrashLoopBackOff`; `kubectl logs -n ords <pod> -c db-check` says why). During a rollout, the old pods keep serving.

| `db-check` says | Meaning | Fix |
|-----------------|---------|-----|
| `Can't log in ...`, with an `ORA-` error above it | The same causes as in the table above: password, account, service name or network | As above |
| `The database's ORDS schema is <x>, but this image is ORDS <y>` | The schema and the image are different versions. ORDS here only serves, so it won't install or upgrade the schema | Have the schema upgraded out of band to the image's version, or set the image to the schema's version ("ORDS upgrades" in [Running the cluster](#running-the-cluster)) |
| `The database's ORDS schema is not installed` | ORDS has never been installed in this database | Have a DBA install it, out of band, at the image's version (see [The database](#the-database)) |

**ORDS is running but unreachable**

| Symptom | Check and fix |
|---------|---------------|
| `kubectl get svc -n ords` shows `EXTERNAL-IP <pending>` | MetalLB hasn't assigned the IP: `kubectl get ipaddresspools -n metallb-system` and `kubectl describe svc ords -n ords`. The address must be inside the pool, and nothing else on the LAN may use it |
| Works directly but not through Cloudflare | Test the cluster without Cloudflare, on k8-control: `curl -sI --resolve www.1apx.com:443:192.168.1.180 https://www.1apx.com/apps/`. If that works, the problem is the router or Cloudflare (next rows) |
| Cloudflare error 521 or 522 ("Web server is down", "Connection timed out") | Cloudflare can't reach your public IP on 443: check the router's port forward, that the Cloudflare record has your current public IP, and that Cloudflare's ranges in `ords.yaml` are current |
| Cloudflare error 525 or 526 (SSL handshake failed, invalid certificate) | Cloudflare doesn't accept ORDS's certificate: it expired, or the chain is incomplete. Check it as in the next row |
| Browser loops between `http://` and `https://` ("too many redirects") | Cloudflare's SSL/TLS mode is "Flexible". Set it to **Full (strict)** |
| Scripts or REST clients get `403` with a "Just a moment..." page | Cloudflare's bot challenge. Add a WAF rule that skips it for those clients |
| No answer from `192.168.1.180` at all | MetalLB's speaker answers ARP for it: `kubectl get pods -n metallb-system -o wide` should show a running speaker on each worker. `ip neigh show 192.168.1.180` on a LAN machine shows which MAC answered |
| Certificate warning in the browser | Check what's served, on k8-control: `openssl s_client -connect 192.168.1.180:443 -servername www.1apx.com -showcerts </dev/null`. Expect `*.1apx.com` and the full chain |
| `/i/` images missing (APEX pages unstyled) | `kubectl logs -n ords <pod> -c db-check` shows the APEX version found (`APEX: 26.1`), and `-c apex-images` should end with "images ready". If the database reports no APEX version, set `APEX_VERSION` in the environment's `ords.env` and redeploy |
| APEX logs users out, or shows "session expired" | APEX keeps sessions in the database, so switching pods doesn't end them. Its session cookie is tied to the host name and HTTPS, so check users open `https://www.1apx.com/...`, not the IP address or `http://`. Then check both pods are `1/1 Ready`: a pod restarting mid-request can fail a page, not a session |

**Suspect the network policies?** Remove both for a moment: `kubectl delete networkpolicy --all -n ords` (removing only `ords` would leave `default-deny` blocking everything but DNS), and test again. If that fixes it, a connection ORDS needs isn't in `k8s/portal/base/network-policy.yaml`: add it there, commit, and run `deploy-ords.sh`, which also restores the policies. If it doesn't help, run `deploy-ords.sh` anyway to put them back.

**Suspect the host firewall?** See "When troubleshooting" under [Firewall](#firewall).

**A rollout doesn't finish.** `kubectl rollout status deployment/ords -n ords` waits for each new pod to be Ready before removing an old one, so a new pod that can't become Ready stops the rollout while the old pods keep serving. Find out why with the tables above, or go back with `kubectl rollout undo deployment/ords -n ords`.

**A worker is `NotReady`.** On the worker: `sudo systemctl status kubelet containerd` and `sudo journalctl -u kubelet -n 50`. If the log says it can't reach `k8-control.1apx.com`, check that `/etc/hosts` still has the `# BEGIN k8s-cluster` block, and re-run `join-workers.sh` if not.

**Look inside a pod.** `kubectl exec -it -n ords deploy/ords -- bash` opens a shell as the `oracle` user. From there, `ords --config /etc/ords/config config list` shows the active settings, and `curl -sk --resolve www.1apx.com:8443:127.0.0.1 https://www.1apx.com:8443/apps/_/landing -o /dev/null -w '%{http_code}\n'` runs the same check as the readiness probe (`200` when the database is reachable).

### B.4 Changing the number of ORDS pods

The cluster runs **two** ORDS pods, one on each worker. The number is `replicas:` in [`k8s/portal/prod/kustomization.yaml`](k8s/portal/prod/kustomization.yaml), and each pod's database connection pool is in [`k8s/portal/prod/ords-pool.conf`](k8s/portal/prod/ords-pool.conf). Change both together, so the pods' connections still add up to what the database expects.

**Pool sizes.** The old single server used `InitialLimit 30`, `MinLimit 50` and `MaxLimit 300`. Divide those by the number of pods:

| Pods | `jdbc.InitialLimit` | `jdbc.MinLimit` | `jdbc.MaxLimit` | Notes |
|------|---------------------|-----------------|-----------------|-------|
| 1 | 30 | 50 | 300 | No redundancy (see below) |
| 2 | 15 | 25 | 150 | Current setting |
| 3 | 10 | 17 | 100 | The most two workers should carry |
| 4 | 8 | 13 | 75 | Add a third worker first |

To allow more connections in total, raise `MaxLimit`, but check the database's limits first. As a DBA, `select name, value from v$parameter where name in ('processes', 'sessions')` shows the limits, and `select count(*) from v$session` shows current use. Every pod keeps at least `MinLimit` sessions open, and can open up to `MaxLimit`.

**Room on the workers.** Each worker has 4 vCPUs and 8 GB of memory. Each ORDS pod reserves 0.5 CPU and 1.5 GiB, and may use up to 3 GiB. Two pods per worker is a sensible maximum, so two workers carry up to **3 pods**. That leaves room for the extra pod a rollout starts before stopping an old one, and for one worker taking every pod while the other is drained. For more pods, add a worker first.

**Add or remove pods.** The steps are the same either way:

1. Edit `count` under `replicas:` in `k8s/portal/prod/kustomization.yaml`.
2. Edit the three `jdbc.*Limit` lines in `k8s/portal/prod/ords-pool.conf` to match the table.
3. Run `ci/validate.sh` and commit.
4. Run `k8s/scripts/deploy-ords.sh`. It asks for no passwords, because they're already stored.
   - **Adding pods:** each new pod downloads the APEX images and starts, which takes a minute or two.
   - **Removing pods:** Kubernetes stops the extra pods. Each finishes its requests during a 10-second grace period first.
   - **Changed pool sizes:** the pods are then also replaced one at a time, so the new sizes take effect without downtime.

Don't use `kubectl scale` for a lasting change. The next `deploy-ords.sh` sets the count back to the one in `kustomization.yaml`. It's fine in an emergency, for example `kubectl scale deployment/ords -n ords --replicas=3`, but then update `kustomization.yaml` as above.

**Check the result:**

| Check | Command |
|-------|---------|
| Number of pods, which worker each is on, and readiness | `kubectl get pods -n ords -o wide`: each pod `1/1 Running`, spread across the workers |
| The rollout finished | `kubectl rollout status deployment/ords -n ords` |
| Pool sizes in use | `kubectl exec -n ords deploy/ords -- ords --config /etc/ords/config config list \| grep -i limit` |
| Database sessions per pod (as a DBA) | `select machine, count(*) from v$session where username = 'ORDS_PUBLIC_USER' group by machine`, one row per pod |

The pods are spread across the workers as a preference: with three pods on two workers, one worker runs two. After a worker has been down, all pods may be on one worker; `kubectl rollout restart deployment/ords -n ords` spreads them again.

**Running a single pod** gives up redundancy. If its worker fails, ORDS is down for about 6–7 minutes: Kubernetes waits 5 minutes before replacing a pod on an unreachable node, and the new pod needs a minute or two to start. Draining that worker for maintenance also causes a short outage. Settings changes, certificate renewals and ORDS upgrades still cause no downtime, because the new pod is ready before the old one stops. The second worker then mostly stands by, as the place the pod moves to when the first is down.

### B.5 Adding an environment (dev, uat)

`k8s/portal/dev` and `k8s/portal/uat` are placeholders, empty but for a README. An overlay there would deploy a second ORDS into the cluster, so set one up only when its database is ready:

1. **Its database:** a separate database or PDB, with the ORDS schema installed at the image's version (out of band, as for production), and its own `ORDS_PUBLIC_USER` password.
2. **Its files:** copy `kustomization.yaml`, `ords.env` and `ords-pool.conf` from `k8s/portal/prod` into the folder, and change:
   - `kustomization.yaml`: `namespace:` to `ords-dev` (or `ords-uat`), `replicas:` (one pod is usually enough), and `images:` if it runs a different ORDS version.
   - `ords.env`: its database (`DB_HOST`, `DB_IP`, `DB_PORT`, `DB_SERVICE`), its host name (for example `dev.1apx.com`, which the `*.1apx.com` certificate covers), and a free address in the MetalLB pool for `LB_IP`. `ci/validate.sh` checks the address is in the pool and not used by another environment.
   - `ords-pool.conf`: a pool size for its pods and database.
3. **Access.** The router forwards port 443 to production only. For access from the LAN (the usual case for dev and uat), add a router DNS record for its host name pointing to its `LB_IP`. Also let the LAN through the Service, which otherwise admits only Cloudflare and the nodes, by adding this to its `kustomization.yaml`. This is safe because no port forward points at that address:
   ```yaml
   patches:
     - target: {kind: Service, name: ords}
       patch: |
         - op: replace
           path: /spec/loadBalancerSourceRanges
           value: ["192.168.1.0/24"]
   ```
   Public access for a second environment needs its own port forward and Cloudflare setup, which this repo doesn't cover.
4. **Room on the workers.** Each ORDS pod reserves 1.5 GiB of memory. Two workers carry about three pods in all (see [B.4](#b4-changing-the-number-of-ords-pods)), so production's two plus one more is the limit: add a worker before adding a second environment.
5. **Deploy it:** run `ci/validate.sh` (it now builds the new environment too), commit, and run `k8s/scripts/deploy-ords.sh dev`. Its namespace is separate, so `kubectl` commands for it need `-n ords-dev`. `health-check.sh` checks production only.

## Appendix C: Recovery, monitoring and lifecycle

Commands run on k8-control, from the repo folder, as `<user>` unless marked `sudo`.

### C.1 Credentials and where they live

The cluster's credentials, where each one is kept, and how to replace it. Keep the values themselves in a password manager, never in this repo or its README.

| Credential | Where it lives | In backups | How to replace it |
|------------|----------------|------------|-------------------|
| `ORDS_PUBLIC_USER` password | The database; the `ords-db-runtime` Secret; each ORDS pod's wallet (rebuilt at every start); the old ORDS server | etcd snapshots (encrypted) | Change it in the database, then [B.2](#b2-day-to-day-operations), "Change the `ORDS_PUBLIC_USER` password" |
| SYS password | The database only. The cluster never stores or uses it: ORDS only serves, and the schema is installed and upgraded out of band | No | The DBA changes it; nothing in the cluster to update |
| `*.1apx.com` private key | `ssl/1apx.key` on k8-control (git-ignored; keep it `0600`); the `ords-tls` Secret; the old ORDS server | etcd snapshots (encrypted). Keep a copy of `ssl/` in the password manager or another safe place | When renewing the certificate, ask for a new key too; then "Renew the certificate" in [B.2](#b2-day-to-day-operations) |
| Secrets encryption key | `/etc/kubernetes/enc/encryption-config.yaml` on k8-control (root only) | `kubernetes-config-*.tgz` | See "Replacing the Secrets encryption key" below |
| Cluster certificates and CA | `/etc/kubernetes/pki` on k8-control | `kubernetes-config-*.tgz` | `sudo kubeadm certs renew all`, then restart the control plane (move the four files in `/etc/kubernetes/manifests` out and back). Upgrades renew them too. The CA lasts 10 years |
| Admin kubeconfigs | `/etc/kubernetes/admin.conf`, copied to `~/.kube/config` for `<user>` and `k8sadmin`. `/etc/kubernetes/super-admin.conf` is a break-glass credential that can't be revoked: keep it root-only and unused | `kubernetes-config-*.tgz` | `sudo kubeadm certs renew admin.conf`, then `sudo k8s/scripts/control-plane-init.sh` copies it again (it skips the steps already done) |
| `k8sadmin` SSH key | `~k8sadmin/.ssh/id_ed25519` on k8-control; its public half in `authorized_keys` on every node | `kubernetes-config-*.tgz` | Generate a new key as `k8sadmin`, add its public half to `~k8sadmin/.ssh/authorized_keys` on each node, check `sudo -iu k8sadmin ssh k8-worker-1 true`, then remove the old public key from every node |
| `<user>`'s GitHub SSH key | `~/.ssh/id_ed25519` on k8-control; the `1apx-codebase` GitHub account | No | Delete it on GitHub and locally, then run `setup-github.sh` |
| Join tokens | Created and deleted by `join-workers.sh` | No | They expire after 30 minutes anyway |
| Proxmox root, router admin, Cloudflare, GitHub and domain registrar logins | Outside the cluster | No | Keep them in the password manager, with two-factor authentication wherever it's offered |

**Replacing the Secrets encryption key** (for example, if a backup containing it was exposed). There's one API server, so this takes two restarts:

1. Generate a key: `head -c 32 /dev/urandom | base64`.
2. In `/etc/kubernetes/enc/encryption-config.yaml`, add it as a new entry *above* `key1`, for example `- name: key2` with `secret: <new key>`. The first key encrypts; the others still decrypt.
3. Restart the API server: move `/etc/kubernetes/manifests/kube-apiserver.yaml` out of that folder, wait until `sudo crictl ps --name kube-apiserver` lists nothing, and move it back.
4. Re-encrypt every Secret with the new key: `kubectl get secrets -A -o json | kubectl replace -f -`.
5. Remove the `key1` entry, and restart the API server again as in step 3.
6. Run `sudo k8s/scripts/etcd-backup.sh`. Older backups still need the old key, which is in their own `kubernetes-config-*.tgz`.

### C.2 Monitoring and alerts

[`k8s/scripts/health-check.sh`](k8s/scripts/health-check.sh) checks, in one run:

- Every node is `Ready`, with no memory, disk or process pressure.
- Every ORDS pod is ready, and ORDS answers at `192.168.1.180` with a working database connection.
- The certificate ORDS serves, and the cluster's own certificates, have at least 30 days left.
- No node's disk is more than 85% full.
- The newest etcd backup is less than 26 hours old.

It prints one line per check, exits non-zero if any fails, and writes the result to the system log (`journalctl -t k8s-health`). The thresholds are at the top of the script.

**Set it up** on k8-control, after the backup cron (the backup check fails until a backup exists):

```bash
sudo install -m 0755 k8s/scripts/health-check.sh /usr/local/sbin/k8s-health-check.sh
echo '*/15 * * * * root /usr/local/sbin/k8s-health-check.sh >/dev/null' | sudo tee /etc/cron.d/k8s-health-check
```

Re-run the `install` command after changing the script.

**Alerts.** A check nobody sees doesn't help, so connect it to a "dead man's switch" service such as [healthchecks.io](https://healthchecks.io) (free for a few checks):

1. Create a check with a period of 15 minutes and a grace time of 30 minutes, and add your email (or another channel) to its notifications.
2. Put its ping URL in `/etc/default/k8s-health-check`, readable only by root:
   ```bash
   echo 'HEALTHCHECK_URL=https://hc-ping.com/<your check id>' | sudo tee /etc/default/k8s-health-check
   sudo chmod 600 /etc/default/k8s-health-check
   ```
3. Run `sudo /usr/local/sbin/k8s-health-check.sh` once and check the service shows the ping.

Every run then reports to the service, with its output. You get an alert when a run fails, and also when runs stop arriving, which covers k8-control itself being down or cron not running.

**Watch the public path too.** The health check tests ORDS directly, inside your network. To know that users can reach it through Cloudflare and the router, add an uptime monitor (healthchecks.io doesn't do this; UptimeRobot, Better Stack and others have free plans) for `https://www.1apx.com/apps/`, every 5 minutes, expecting a `302` or `200`. If the monitor gets `403` with a "Just a moment..." page, Cloudflare's bot protection is challenging it. Let it through with a WAF custom rule whose action is **Skip** for the monitor's requests. Cloudflare's free-plan Bot Fight Mode can't be skipped this way: if that's what challenges it, turn Bot Fight Mode off, or rely on the internal health check alone.

**Calendar reminders,** as a second line for what can't be renewed automatically:

- The `*.1apx.com` certificate expires on **2 January 2027**: set a reminder for early December 2026. The health check also fails from 30 days before.
- The cluster's certificates expire one year after `kubeadm init` (`sudo kubeadm certs check-expiration` shows the date). Upgrading Kubernetes renews them, so a yearly upgrade keeps them current.

**When an alert arrives,** run `sudo k8s/scripts/health-check.sh` to see which check fails, then use [B.3](#b3-troubleshooting).

### C.3 Access logs

Each ORDS pod writes an access log, one line per request, and its `access-log` sidecar container prints it:

```bash
kubectl logs -n ords -l app=ords -c access-log --prefix --tail=50   # recent requests on every pod
kubectl logs -n ords <pod> -c access-log -f                         # follow one pod
```

A line looks like this:

```text
172.70.1.20 - [15/Oct/2026:14:43:12 +0000] "GET /apps/r/myapp/home HTTP/1.1" 200 5123 "https://www.1apx.com/apps/..." "Mozilla/5.0 ..." 110 www.1apx.com:8443 - -
```

The fields are the connecting address, the time, the request, the status code, the response size, the referrer, the user agent, the time taken (milliseconds) and the host. ORDS also logs every failed request, with its error, in the ORDS container's own log (`kubectl logs -n ords <pod>`).

Things to know:

- **The address isn't the visitor's.** It's the Cloudflare server that forwarded the request, or a worker's address when the request reached the pod through the other worker. ORDS ignores `X-Forwarded-For` and `CF-Connecting-IP`; in ORDS 26.2 that handling is switched off in its code (checked in 26.2.3), so no setting changes it. Visitors' real addresses are in Cloudflare's dashboard: **Security → Events** for requests Cloudflare blocked or challenged, and **Analytics** for traffic overall. Cloudflare's per-request logs (Logpush) need its Enterprise plan.
- **Short retention.** Each pod keeps two days of log files, and they disappear when the pod is replaced (every deploy or restart). The node keeps a little more of the sidecar's output (by default five files of 10 MB per container). For longer retention or searching, add a log collector, such as Grafana Loki with Grafana Alloy on each node. None is set up.

### C.4 Backups and restore

**What's backed up, and what isn't:**

| What | Where | Kept |
|------|-------|------|
| Cluster state: every Kubernetes object, including the Secrets (encrypted) | `etcd-<date>.db` in `/var/backups/kubernetes` on k8-control, by `etcd-backup.sh` | 14 days |
| Certificates, kubeconfigs, control-plane manifests, the Secrets encryption key, kubelet's credentials and config, `k8sadmin`'s SSH key | `kubernetes-config-<date>.tgz`, same place | 14 days |
| `etcdutl`, the restore tool matching the cluster's etcd | `etcdutl`, same place | Replaced by each backup |
| The three VMs, whole | Proxmox scheduled backups (vzdump), which you set up in Proxmox | As set there |
| The database | **Not here.** The database's own backups (see [The database](#the-database)) | |
| The `ssl/` certificate files | **Not here** (git-ignored). Keep a copy in the password manager or another safe place | |
| This repo | GitHub | |

Copy `/var/backups/kubernetes` off k8-control regularly (for example with `rsync` from another machine), and keep the copies private: they contain the cluster's private keys.

**Which recovery to use:**

| What happened | Do this |
|---------------|---------|
| A bad change to ORDS (settings, image, manifests) | No restore: `kubectl rollout undo deployment/ords -n ords`, or revert the commit and run `deploy-ords.sh` |
| Something in the `ords` namespace was deleted | No restore: run `deploy-ords.sh`, which recreates everything (it asks for the `ORDS_PUBLIC_USER` password if its Secret is gone) |
| A worker VM is lost | `kubectl delete node <worker>`, recreate the VM with `proxmox-create-workers.sh` (it skips the VM that still exists), then `sudo k8s/scripts/join-workers.sh` |
| k8-control is lost, and a Proxmox backup of it exists | Restore the VM in Proxmox. This is the fastest way back. If the backup is more than a few hours old, also restore the newest etcd snapshot (procedure A) |
| k8-control is lost, with no Proxmox backup | Procedure B |
| etcd's data is damaged, k8-control is otherwise fine | Procedure A |
| Everything is lost, or the restore fails | Procedure C: build a new cluster. ORDS keeps no state, so nothing is lost but time (about an hour) |

**Rehearse procedure A** soon after the cluster is built, and after each Kubernetes upgrade: an untried restore often fails when it's needed. It takes about ten minutes, and ORDS keeps serving while the control plane is down.

**Procedure A: restore an etcd snapshot on k8-control.** Pick the snapshot (`ls -l /var/backups/kubernetes`), then:

```bash
B=/var/backups/kubernetes
SNAP=$B/etcd-<date>.db                      # the snapshot to restore
sudo mkdir -p /root/manifests-hold
sudo mv /etc/kubernetes/manifests/*.yaml /root/manifests-hold/      # stops the control plane
while sudo crictl ps -q --name 'etcd|kube-apiserver' | grep -q .; do sleep 2; done
sudo mv /var/lib/etcd "/var/lib/etcd.before-restore-$(date +%F-%H%M)"
sudo "$B/etcdutl" snapshot restore "$SNAP" --data-dir /var/lib/etcd \
  --name k8-control --initial-cluster k8-control=https://192.168.1.170:2380 \
  --initial-advertise-peer-urls https://192.168.1.170:2380
sudo mv /root/manifests-hold/*.yaml /etc/kubernetes/manifests/      # starts it again
```

Then wait until `kubectl get nodes` answers, restart kubelet on every node so they pick up the restored state (`sudo systemctl restart kubelet` on k8-control, and through `sudo -iu k8sadmin ssh <worker> sudo systemctl restart kubelet`), and run `sudo k8s/scripts/health-check.sh`. When all is well, delete `/var/lib/etcd.before-restore-*`.

**Procedure B: rebuild k8-control from its backups.**

1. Create a VM like the old one (Ubuntu 26.04, same name `k8-control`, same disk size), and run [`apply-changes.sh`](#apply-all-changes) for its address and DNS.
2. Clone this repo, then run `sudo k8s/scripts/create-admin-user.sh` and `sudo k8s/scripts/node-prep.sh` (from the console: it turns on the firewall).
3. Copy the newest backup files (an `etcd-*.db`, the `kubernetes-config-*.tgz` from the same run, and `etcdutl`) into `/var/backups/kubernetes`, owned by root and `0600`.
4. Put back the configuration, credentials and keys: `sudo tar -xzpf /var/backups/kubernetes/kubernetes-config-<date>.tgz -C /`. This replaces the new `k8sadmin` key with the old one, which the workers accept.
5. Restore etcd: run the `etcdutl snapshot restore` command from procedure A (`/var/lib/etcd` doesn't exist yet, so skip the steps before it).
6. `sudo systemctl restart kubelet`. It starts the control plane from the restored manifests; after a minute or two, `sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes` answers, and the workers reconnect by themselves.
7. `sudo k8s/scripts/control-plane-init.sh` copies the admin kubeconfig to `<user>` and `k8sadmin` (the steps already done are skipped).
8. Set up the backup and health-check crons again (the headers of `etcd-backup.sh` and `health-check.sh`), and run the health check.

**Procedure C: build a new cluster.** On each surviving worker, `sudo kubeadm reset -f` (as `k8sadmin` over SSH, or from the Proxmox console). If k8-control is a new VM, first put back `k8sadmin`'s old SSH key, which the workers accept: after Step 1, `sudo tar -xzpf <a kubernetes-config-*.tgz> -C / home/k8sadmin/.ssh`; without a backup, recreate the workers instead. Then follow Steps 3 to 7 again, on new VMs where needed. `deploy-ords.sh` asks for the `ORDS_PUBLIC_USER` password and needs the `ssl/` files. DNS, Cloudflare and the router need no change, because the addresses stay the same.

### C.5 Upgrades, step by step

**Before any upgrade:**

- Read the release notes of the target version, and check that Calico supports it (Calico's "System requirements" page lists the Kubernetes versions each release is tested with).
- Move up one minor version at a time: 1.36 → 1.37, never 1.36 → 1.38. Patch releases (1.36.5 → 1.36.6) follow the same steps.
- `sudo k8s/scripts/etcd-backup.sh`, and `sudo k8s/scripts/health-check.sh` shows everything `ok`.

**1. Update the repo.** Set `K8S_MINOR` and `K8S_VERSION` in `node-prep.sh`, `kubernetesVersion` in `kubeadm-config.yaml`, and the three `pod-security.kubernetes.io/*-version` labels in `k8s/common/namespace.yaml`. Run `ci/validate.sh` and commit.

**2. Upgrade the control plane,** on k8-control. Set `V` to the target version; change both `v1.36` and `v1.37` to match your upgrade:

```bash
V=1.37.1
sudo sed -i 's|/v1.36/|/v1.37/|' /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-mark unhold kubeadm && sudo apt-get install -y "kubeadm=$V-*" && sudo apt-mark hold kubeadm
sudo kubeadm upgrade plan                       # check it offers v$V and reports no problems
sudo kubeadm upgrade apply "v$V"                # also renews the cluster certificates
kubectl drain k8-control --ignore-daemonsets --delete-emptydir-data
sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y "kubelet=$V-*" "kubectl=$V-*" && sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon k8-control
sudo k8s/scripts/node-prep.sh                   # containerd's pause image for the new version
```

**3. Upgrade each worker,** one at a time, from k8-control. The other worker carries ORDS meanwhile:

```bash
V=1.37.1 W=k8-worker-1
kubectl drain "$W" --ignore-daemonsets --delete-emptydir-data
sudo -iu k8sadmin ssh "$W" "sudo sed -i 's|/v1.36/|/v1.37/|' /etc/apt/sources.list.d/kubernetes.list \
  && sudo apt-get update && sudo apt-mark unhold kubeadm kubelet kubectl \
  && sudo apt-get install -y 'kubeadm=$V-*' && sudo kubeadm upgrade node \
  && sudo apt-get install -y 'kubelet=$V-*' 'kubectl=$V-*' && sudo apt-mark hold kubeadm kubelet kubectl \
  && sudo systemctl daemon-reload && sudo systemctl restart kubelet"
kubectl uncordon "$W"
kubectl wait --for=condition=Ready "node/$W" --timeout=300s
```

**4. Finish:** `sudo k8s/scripts/join-workers.sh` re-runs `node-prep.sh` on the workers (for the pause image) and skips the join. `kubectl get nodes` shows the new version on all three. `kubectl rollout restart deployment/ords -n ords` spreads the ORDS pods again, and `sudo k8s/scripts/health-check.sh` should pass.

**Calico.** Upgrade it when the next Kubernetes version needs it, and read Calico's upgrade guide for the target release first:

1. Set `CALICO_VERSION` in `control-plane-init.sh`, update its three lines in `k8s/config/upstream.sha256` (`curl -fsSL <url> | sha256sum`), run `ci/validate.sh` and commit.
2. On k8-control, download the two operator files, check them against the pins, and apply them:
   ```bash
   REPO=$PWD C=v3.33.0; u=https://raw.githubusercontent.com/projectcalico/calico/$C/manifests
   cd "$(mktemp -d)" && curl -fsSL -O "$u/operator-crds.yaml" -O "$u/tigera-operator.yaml" \
     && grep -E "/$C/manifests/(operator-crds|tigera-operator)\.yaml" "$REPO/k8s/config/upstream.sha256" \
          | sed 's|  https://.*/|  |' | sha256sum -c \
     && kubectl apply --server-side --force-conflicts -f operator-crds.yaml -f tigera-operator.yaml \
     && kubectl rollout status daemonset/calico-node -n calico-system --timeout=600s
   cd "$REPO"
   ```

**MetalLB and metrics-server.** Read the release notes for breaking changes. Change `METALLB_VERSION` or `METRICS_SERVER_VERSION` in `cluster-addons.sh` and their lines in `upstream.sha256`, validate, commit, and run `k8s/scripts/cluster-addons.sh` again: it applies the new versions.

**ORDS** upgrades are in [Running the cluster](#running-the-cluster).

### C.6 Testing changes

There's no separate test cluster: every change goes to the live one. These keep that safe:

- **Before committing:** `ci/validate.sh` checks the scripts, the manifests as `deploy-ords.sh` renders them, Pod Security, and the values that must agree across files.
- **Before deploying:** `k8s/scripts/deploy-ords.sh --diff` shows what a deploy would change in the cluster (everything in the environment's overlay: the namespace, network policies, ConfigMaps and the ORDS objects), without changing anything. It doesn't show Secrets, or the effects of a different database version.
- **While deploying:** new pods must pass their readiness check before an old one stops (`maxUnavailable: 0`). A change that breaks ORDS leaves the rollout stuck with the old pods still serving, and `deploy-ords.sh` fails after 20 minutes.
- **Going back:** `kubectl rollout undo deployment/ords -n ords` returns to the previous pods at once. To make it permanent, revert the commit and run `deploy-ords.sh`.

For changes that touch the database (an ORDS schema upgrade, done out of band, or a new APEX version), ask for a database backup first and pick a quiet time: a schema upgrade can't be undone by Kubernetes. For larger experiments, a small second cluster built from this repo, with its own address and host name, is the safe place.

### C.7 Retiring the old ORDS server

After cutover, the old server is the way back, so keep it until the cluster has proved itself:

1. **Keep it running, unchanged,** for two to four weeks. Rolling back is restoring `www`'s old records in Cloudflare (noted at cutover).
2. **Find anything still using it.** Its access log shows requests that don't come through `www.1apx.com`: other host names, its IP address, internal systems or scripts. Move each of those to `https://www.1apx.com/`.
3. **Keep the versions in step.** When the ORDS schema is upgraded (out of band), upgrade the old server to the same ORDS version, or stop it.
4. **Stop ORDS on it,** and leave the machine off (not deleted) for another few weeks.
5. **Clean up:**
   - Delete its copy of the `*.1apx.com` private key, and its ORDS configuration and wallet, which hold the `ORDS_PUBLIC_USER` password.
   - Remove its DNS records and router port forwards, and its address from the database server's firewall.
   - Change the `ORDS_PUBLIC_USER` password ([B.2](#b2-day-to-day-operations)), since the old server knew it.
   - Remove it from [Ownership and contacts](#ownership-and-contacts), and add an entry to the change log.

### C.8 Taking the cluster down

If the cluster is ever retired or replaced, in this order:

1. **Point users elsewhere first:** change or remove the `www.1apx.com` record in Cloudflare. Otherwise the site goes down as soon as the cluster does.
2. **Router:** remove the port 443 forward to `192.168.1.180`, and the address reservations.
3. **Monitoring:** delete the healthchecks.io check and the uptime monitor, or they'll alert.
4. **ORDS:** `kubectl delete namespace ords` (this also deletes its Secrets, with the password and TLS key).
5. **Workers,** on the Proxmox host: `qm stop 211 && qm destroy 211 --purge`, the same for 212, and `qm destroy 9000` for the template if nothing else uses it.
6. **k8-control:**
   ```bash
   sudo kubeadm reset -f
   sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/etcd /var/log/kubernetes
   sudo rm -f /etc/cron.d/etcd-backup /etc/cron.d/k8s-health-check /etc/default/k8s-health-check \
     /usr/local/sbin/etcd-backup.sh /usr/local/sbin/k8s-health-check.sh
   sudo apt-mark unhold kubelet kubeadm kubectl && sudo apt-get purge -y kubelet kubeadm kubectl
   sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   sudo sed -i '/^# BEGIN k8s-cluster$/,/^# END k8s-cluster$/d' /etc/hosts
   sudo userdel -r k8sadmin && sudo rm -f /etc/sudoers.d/k8sadmin
   sudo reboot                                    # clears the network rules Kubernetes left
   ```
   The firewall (ufw) stays on with the cluster's rules; remove them with `sudo ufw status numbered` and `sudo ufw delete <number>`, keeping the SSH rule.
7. **Backups:** once nothing needs them, delete `/var/backups/kubernetes` and every copy of it, and the Proxmox backups of the workers. They contain the cluster's private keys.
8. **Database:** remove the workers' addresses from its firewall. The ORDS schema stays: other ORDS servers may use it.
9. **This repo:** add a final change-log entry, and archive it on GitHub (**Settings → General → Archive this repository**).
