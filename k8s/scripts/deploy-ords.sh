#!/usr/bin/env bash
# Deploy ORDS (the portal application) from its Kustomize overlay, k8s/portal/<environment>,
# serving HTTPS with the *.1apx.com certificate. ORDS only serves: neither this script nor
# the pods install or upgrade the ORDS schema in the database, which is done out of band.
# Run on k8-control as your own login (not root) after cluster-addons.sh:
#   k8s/scripts/deploy-ords.sh [prod|uat|dev] [--diff]
#     prod|uat|dev   the environment; prod if not given
#     --diff         only show what a deploy would change in the cluster; changes nothing
# Safe to re-run; re-run after changing the overlay or the settings, or renewing the certificate.
set -euo pipefail

ENV=prod
DIFF=false
for a in "$@"; do
  case $a in
    prod|uat|dev) ENV=$a ;;
    --diff) DIFF=true ;;
    *) echo "Usage: $0 [prod|uat|dev] [--diff]" >&2; exit 1 ;;
  esac
done

# Certificate files (kept out of git by .gitignore)
K8S=$(cd "$(dirname "$0")/.." && pwd)   # the k8s/ folder
SSL_DIR="$(cd "$K8S/.." && pwd)/ssl"
CERT_FILE=1apx_com.crt            # server certificate
CHAIN_FILE=1apx_com.ca-bundle     # intermediate certificates
KEY_FILE=1apx.key                 # private key (any format; converted to PKCS#8, which ORDS needs)

OVERLAY="$K8S/portal/$ENV"
[ "$(id -u)" -ne 0 ] || { echo "Run as your own login, not root." >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "Needs Python's yaml module: sudo apt install python3-yaml" >&2; exit 1; }
[ -f "$OVERLAY/kustomization.yaml" ] \
  || { echo "The $ENV environment isn't set up yet: see $OVERLAY/README.md." >&2; exit 1; }
NAMESPACE=$(sed -n 's/^namespace: *//p' "$OVERLAY/kustomization.yaml")
val() { sed -n "s/^$1=//p" "$OVERLAY/ords.env" | tail -1; }
DB_HOST=$(val DB_HOST) DB_IP=$(val DB_IP) ORDS_HOSTNAME=$(val ORDS_HOSTNAME) LB_IP=$(val LB_IP)
resolved=$(getent ahostsv4 "$DB_HOST" 2>/dev/null | awk '{print $1}' | sort -u | xargs || true)
if [ -z "$DB_IP" ]; then
  echo "Set DB_IP in $OVERLAY/ords.env to the database's IPv4 address${resolved:+ ($DB_HOST resolves to $resolved here)}." >&2
  exit 1
fi
if [ -n "$resolved" ] && [[ " $resolved " != *" $DB_IP "* ]]; then
  echo "WARNING: $DB_HOST resolves to $resolved, but DB_IP is $DB_IP. The pods use DB_IP."
fi

# Private work folder (0700) for the build, the TLS files and passwords while they're stored
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
kubectl kustomize "$OVERLAY" > "$work/build.yaml"

if [ "$DIFF" = true ]; then
  # Everything in the overlay. The Secrets aren't in it: only a real deploy reads those.
  # kubectl diff exits 1 when there are differences.
  rc=0
  kubectl diff -f "$work/build.yaml" || rc=$?
  case $rc in
    0) echo "No differences: a deploy would change nothing in $NAMESPACE (apart from the Secrets)." ;;
    1) echo "Differences above. A changed ConfigMap appears under a new name, and replaces the pods one at a time." ;;
    *) echo "kubectl diff failed (exit $rc)." >&2; exit "$rc" ;;
  esac
  exit 0
fi

ask_password() {   # ask_password "label" -> prints the password; never echoed or saved
  local a b
  [ -t 0 ] || { echo "Asking for the $1 needs a terminal: run this script interactively." >&2; exit 1; }
  while true; do
    read -rsp "$1: " a || exit 1; echo >&2
    read -rsp "Repeat $1: " b || exit 1; echo >&2
    [ -n "$a" ] && [ "$a" = "$b" ] && break
    echo "Passwords were empty or didn't match, try again." >&2
  done
  printf '%s' "$a"
}
# Secrets are applied server-side: a client-side apply would also keep a full copy of each,
# values included, in its kubectl.kubernetes.io/last-applied-configuration annotation
apply_secret() { kubectl apply --server-side --force-conflicts --field-manager=deploy-ords -f -; }
secret_version() { kubectl get secret "$1" -n "$NAMESPACE" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true; }

# 1. The namespace first, from the build (with its Pod Security labels), to hold the Secrets
python3 -c 'import sys, yaml
print(yaml.safe_dump([d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Namespace"][0]))' \
  "$work/build.yaml" | kubectl apply -f -

# 2. TLS certificate: check it, then store chain + PKCS#8 key as the ords-tls Secret
for f in "$CERT_FILE" "$CHAIN_FILE" "$KEY_FILE"; do
  [ -r "$SSL_DIR/$f" ] || { echo "Missing $SSL_DIR/$f" >&2; exit 1; }
done
openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -checkhost "$ORDS_HOSTNAME" | grep -q "does match" \
  || { echo "The certificate doesn't cover $ORDS_HOSTNAME." >&2; exit 1; }
openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -checkend 0 >/dev/null \
  || { echo "The certificate has expired." >&2; exit 1; }
openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -checkend $((30*86400)) >/dev/null \
  || echo "WARNING: the certificate expires within 30 days: $(openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -enddate)"
cat "$SSL_DIR/$CERT_FILE" "$SSL_DIR/$CHAIN_FILE" > "$work/tls.crt"
openssl pkey -in "$SSL_DIR/$KEY_FILE" -out "$work/tls.key"
cert_pub=$(openssl x509 -in "$work/tls.crt" -noout -pubkey | openssl sha256)
key_pub=$(openssl pkey -in "$work/tls.key" -pubout | openssl sha256)
if [ -z "$cert_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
  echo "$KEY_FILE doesn't match $CERT_FILE." >&2
  exit 1
fi
secrets_before="$(secret_version ords-tls) $(secret_version ords-db-runtime)"
kubectl create secret tls ords-tls -n "$NAMESPACE" --cert="$work/tls.crt" --key="$work/tls.key" \
  --dry-run=client -o yaml | apply_secret
rm -f "$work/tls.crt" "$work/tls.key"
echo "Certificate: $(openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -subject -enddate | tr '\n' ' ')"

# 3. ORDS_PUBLIC_USER password (kept off the command line)
if ! kubectl get secret ords-db-runtime -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Enter the ORDS_PUBLIC_USER password the existing ORDS server uses (its pool's db.password)."
  pw=$(ask_password 'ORDS_PUBLIC_USER password')
  printf '%s' "$pw" > "$work/ORACLE_USER_PWD"
  unset pw
  kubectl create secret generic ords-db-runtime -n "$NAMESPACE" --from-file="ORACLE_USER_PWD=$work/ORACLE_USER_PWD" \
    --dry-run=client -o yaml | apply_secret
  rm -f "$work/ORACLE_USER_PWD"
fi
secrets_after="$(secret_version ords-tls) $(secret_version ords-db-runtime)"

# 4. Everything else in the overlay. A changed ConfigMap gets a new name (the hash of its
#    contents), which changes the pod template, so the pods are replaced one at a time.
generation=$(kubectl get deployment ords -n "$NAMESPACE" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
kubectl apply -f "$work/build.yaml"
# The pods read the Secrets only when they start: if only a Secret changed, replace them
if [ -n "$generation" ] && [ "$secrets_before" != "$secrets_after" ] \
   && [ "$generation" = "$(kubectl get deployment ords -n "$NAMESPACE" -o jsonpath='{.metadata.generation}')" ]; then
  echo "A Secret changed: replacing the pods one at a time."
  kubectl rollout restart deployment/ords -n "$NAMESPACE"
fi

# 5. Wait for the rollout. Each new pod first checks the database (its db-check step); if that
#    fails, the old pods keep serving, and its log says why.
echo "Waiting for ORDS (each new pod checks the database, then downloads the APEX images)..."
if ! kubectl rollout status deployment/ords -n "$NAMESPACE" --timeout=15m; then
  kubectl get pods -n "$NAMESPACE" -l app=ords -o wide >&2
  echo "--- db-check, the database check, on each pod:" >&2
  kubectl logs -n "$NAMESPACE" -l app=ords -c db-check --prefix --tail=15 >&2 || true
  echo "The rollout didn't finish; any old pods keep serving. See README, Appendix B.3." >&2
  exit 1
fi
kubectl logs -n "$NAMESPACE" -l app=ords -c db-check --tail=1 --prefix 2>/dev/null || true
kubectl get pods,svc -n "$NAMESPACE" -o wide

# 6. Delete generated ConfigMaps that nothing uses any more: neither this build nor a
#    ReplicaSet kept for "kubectl rollout undo"
keep=" $(sed -n 's/^  name: \(ords-[a-z]*-[a-z0-9]\{10\}\)$/\1/p' "$work/build.yaml" | xargs) \
$(kubectl get replicasets -n "$NAMESPACE" -l app=ords -o jsonpath='{..configMapRef.name} {..configMap.name}') "
for cm in $(kubectl get configmaps -n "$NAMESPACE" -l app.kubernetes.io/part-of=portal -o name | cut -d/ -f2); do
  [[ $keep == *" $cm "* ]] || kubectl delete configmap "$cm" -n "$NAMESPACE"
done

# 7. Test ORDS directly at LB_IP, bypassing Cloudflare and DNS (the public name resolves to
#    Cloudflare). k8-control is one of the nodes, which the Service allows.
direct() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$ORDS_HOSTNAME:443:$LB_IP" "https://$ORDS_HOSTNAME$1" || true; }
apps=$(direct /apps/)
root=$(direct /)
if [[ $apps =~ ^(200|302)$ ]] && [ "$root" = 200 ]; then
  echo "Direct test OK: /apps/ answers $apps, / answers $root (a page that redirects to /apps/)."
else
  echo "WARNING: direct test: /apps/ answered '$apps' (expected 302 or 200), / answered '$root' (expected 200)." >&2
fi
echo "Users reach https://$ORDS_HOSTNAME/ through Cloudflare; / redirects to /apps/."
