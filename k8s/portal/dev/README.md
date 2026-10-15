# dev: not set up yet

This is where the portal's dev environment will go. It's empty on purpose: an overlay here
would deploy a second ORDS into the cluster, and dev needs its own database, host name and
address first.

To set it up, copy the files from [`../prod`](../prod) and change:

- `kustomization.yaml`: `namespace: ords-dev`, the replica count, and the image if dev runs a
  different ORDS version.
- `ords.env`: dev's database (`DB_HOST`, `DB_IP`, `DB_PORT`, `DB_SERVICE`), its host name
  (for example `dev.1apx.com`, which `*.1apx.com` covers) and a free address in the MetalLB pool
  for `LB_IP`.
- `ords-pool.conf`: the pool size for dev's pods and database.

Then deploy it with `k8s/scripts/deploy-ords.sh dev`. `ci/validate.sh` builds and checks
every environment that has a `kustomization.yaml`. The README (Appendix B.5) covers the
Cloudflare record, router and certificate a public environment also needs.
