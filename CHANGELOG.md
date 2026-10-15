# Change log

Significant changes to the cluster and to how it's run, newest first. `git log` has the details.
Add an entry for each change that matters to someone running the cluster: what changed, and why.

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
