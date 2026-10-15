# Change log

Significant changes to the cluster and to how it's run, newest first. `git log` has the details.
Add an entry for each change that matters to someone running the cluster: what changed, and why.

## 2026-10-15: Kustomize layout; ORDS serve-only

- **Kustomize, three levels:** `k8s/common` (namespace with Pod Security "restricted", a
  deny-all network policy except DNS) -> `k8s/portal/base` (ORDS) -> `k8s/portal/prod`
  (production's values, pool size, replicas and image). `dev` and `uat` are placeholders.
  Each environment's values are in one file, `ords.env`; settings changes roll the pods
  through content-hashed ConfigMap names.
- **ORDS only serves:** the schema install/upgrade Job, the SYS password handling and
  `INSTALL_OR_UPGRADE_SCHEMA` are gone. Schema installs and upgrades are done out of band by
  a DBA. A `db-check` step in each pod replaces the preflight pod: it refuses to start ORDS
  against a schema of another version, and finds the APEX version.
- **Database address:** set once per environment (`DB_IP`, `192.168.1.110` for production); the
  pods map the database's name to it themselves, so they no longer depend on DNS for it.
- **ORDS 26.2.0:** the database's ORDS schema is 26.2.0 (and its APEX 26.1), so production now
  runs the 26.2.0 image, not 26.2.3. Tested against the database: login with encryption
  required, the version check, the APEX 26.1 images, and APEX's sign-in page through ORDS.

## 2026-10-15: Initial build

The cluster and ORDS deployment were designed, reviewed and documented in one day, before the
cluster was built. The state at the end of the day:

- **Host k8-control:** static IP `192.168.1.170`, DNS servers `192.168.1.1` and `8.8.8.8`,
  passwordless sudo for the personal login, Claude Code's classic interface for mouse copy.
- **Cluster:** Kubernetes 1.36.5 with kubeadm on three Ubuntu 26.04 VMs (k8-control and two
  workers on the Proxmox ZFS storage `zfs-pool-data`); Calico 3.32.2; MetalLB 0.16.1 with the
  pool `192.168.1.180`–`189`; metrics-server 0.9.0. Secrets encrypted at rest, API audit log,
  host firewall, upstream files pinned by SHA-256.
- **ORDS 26.2.3:** two pods behind `192.168.1.180`, serving `https://www.1apx.com/` through
  Cloudflare and the router's port 443 forward; only Cloudflare's addresses and the nodes may
  connect. Settings copied from the old server, with the Database API off and the connection
  pool split between the pods. The database is reached only at its own address, with
  encryption required.
- **Hardening:** Pod Security "restricted" enforced; non-root containers with read-only root
  filesystems and no capabilities; no host folders; a network policy allowing only what ORDS
  needs; image pinned by digest.
- **Operations:** daily etcd backups including what a restore needs, a health check with
  alerting, an ORDS access log, `deploy-ords.sh --diff`, and CI (`ci/validate.sh`) on every push
  and weekly.
- **Requirement found:** the ORDS image needs an x86-64-v3 (AVX2) CPU on the workers.

Still to happen: building the cluster, the cutover from the old ORDS server, and the first
restore rehearsal (Appendix C.4 of the README).
