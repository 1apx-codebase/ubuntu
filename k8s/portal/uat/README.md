# uat: not set up yet

This is where the portal's uat environment will go. It's empty on purpose: an overlay here
would deploy a second ORDS into the cluster, and uat needs its own database, host name and
address first.

To set it up, copy the files from [`../prod`](../prod) and change:

- `kustomization.yaml`: `namespace: ords-uat`, the replica count, and the image if uat runs a
  different ORDS version.
- `ords.env`: uat's database (`DB_HOST`, `DB_IP`, `DB_PORT`, `DB_SERVICE`), its host name
  (for example `uat.1apx.com`, which `*.1apx.com` covers) and a free address in the MetalLB pool
  for `LB_IP`.
- `ords-pool.conf`: the pool size for uat's pods and database.

Then deploy it with `k8s/scripts/deploy-ords.sh uat`. `ci/validate.sh` builds and checks
every environment that has a `kustomization.yaml`. The README's Appendix B.5 has the full
steps, including LAN access and the room it needs on the workers.
