#!/usr/bin/env bash
# Deploy Oracle REST Data Services (ORDS) to the cluster, connected to the existing
# Oracle database and serving HTTPS with the *.1apx.com certificate.
# Run on k8-control as vaviles after cluster-addons.sh: ./deploy-ords.sh
# Safe to re-run; re-run after changing ords-settings.conf or renewing the certificate.
set -euo pipefail

NAMESPACE=ords
# Use the tag that matches the ORDS version installed in the database (the
# preflight check reports it). Tags: container-registry.oracle.com/database/ords
ORDS_IMAGE=container-registry.oracle.com/database/ords:26.2.3
ORDS_HOSTNAME=ords.1apx.com       # needs a DNS record pointing at LB_IP
LB_IP=192.168.1.180               # from the MetalLB range in cluster-addons.sh

# Existing Oracle database (from the old server's pool.xml)
DB_HOST=node.1apx.com
DB_PORT=1521
DB_SERVICE=pdb1                   # the PDB service name, not the CDB
# IP of DB_HOST, only if DB_HOST has no DNS record (node.1apx.com didn't resolve when
# this was written). The pods then map DB_HOST to this IP, like an /etc/hosts entry.
DB_HOST_IP=

# APEX version for the /i/ static images, as major.minor (24.2, 26.1, ...).
# Leave empty to use the version the preflight check finds in the database.
APEX_VERSION=

# Install or upgrade the ORDS schema in the database. Only needed when the
# database's ORDS version differs from ORDS_IMAGE. This changes the schema for
# every ORDS server using this database, so upgrade any other ORDS server too.
INSTALL_OR_UPGRADE_SCHEMA=false

# Certificate files (kept out of git by .gitignore)
SSL_DIR="$(cd "$(dirname "$0")/../.." && pwd)/ssl"
CERT_FILE=1apx_com.crt            # server certificate
CHAIN_FILE=1apx_com.ca-bundle     # intermediate certificates
KEY_FILE=1apx.key                 # private key (any format; converted to PKCS#8, which ORDS needs)

K8S=$(cd "$(dirname "$0")/.." && pwd)   # the k8s/ folder
MANIFESTS="$K8S/manifests/ords"
[ "$(id -u)" -ne 0 ] || { echo "Run as vaviles, not root." >&2; exit 1; }
ORDS_TAG=${ORDS_IMAGE##*:}
HOST_ALIASES="[]"
[ -z "$DB_HOST_IP" ] || HOST_ALIASES="[{ip: \"$DB_HOST_IP\", hostnames: [\"$DB_HOST\"]}]"
render() {
  sed -e "s|__ORDS_IMAGE__|$ORDS_IMAGE|g" -e "s|__ORDS_HOSTNAME__|$ORDS_HOSTNAME|g" -e "s|__LB_IP__|$LB_IP|g" \
      -e "s|hostAliases: \[\]|hostAliases: $HOST_ALIASES|" "$1"
}
if [ -z "$DB_HOST_IP" ] && ! getent hosts "$DB_HOST" >/dev/null; then
  echo "$DB_HOST doesn't resolve. Add a DNS record for it, or set DB_HOST_IP in this script." >&2
  exit 1
fi

ask_password() {   # ask_password "label" -> prints the password; never echoed or saved
  local a b
  while true; do
    read -rsp "$1: " a; echo >&2
    read -rsp "Repeat $1: " b; echo >&2
    [ -n "$a" ] && [ "$a" = "$b" ] && break
    echo "Passwords were empty or didn't match, try again." >&2
  done
  printf '%s' "$a"
}

secret_from_value() {   # secret_from_value name key value (keeps the value off the command line)
  local d
  d=$(mktemp -d)
  printf '%s' "$3" > "$d/$2"
  kubectl create secret generic "$1" -n "$NAMESPACE" --from-file="$2=$d/$2" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -rf "$d"
}

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 1. TLS certificate: check it, then store chain + PKCS#8 key as the ords-tls Secret
for f in "$CERT_FILE" "$CHAIN_FILE" "$KEY_FILE"; do
  [ -r "$SSL_DIR/$f" ] || { echo "Missing $SSL_DIR/$f" >&2; exit 1; }
done
openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -checkhost "$ORDS_HOSTNAME" | grep -q "does match" \
  || { echo "The certificate doesn't cover $ORDS_HOSTNAME." >&2; exit 1; }
openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -checkend 0 >/dev/null \
  || { echo "The certificate has expired." >&2; exit 1; }
openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -checkend $((30*86400)) >/dev/null \
  || echo "WARNING: the certificate expires within 30 days: $(openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -enddate)"
tls=$(mktemp -d)
trap 'rm -rf "$tls"' EXIT
chmod 700 "$tls"
cat "$SSL_DIR/$CERT_FILE" "$SSL_DIR/$CHAIN_FILE" > "$tls/tls.crt"
openssl pkey -in "$SSL_DIR/$KEY_FILE" -out "$tls/tls.key"
[ "$(openssl x509 -in "$tls/tls.crt" -noout -pubkey | openssl sha256)" = \
  "$(openssl pkey -in "$tls/tls.key" -pubout | openssl sha256)" ] \
  || { echo "$KEY_FILE doesn't match $CERT_FILE." >&2; exit 1; }
kubectl create secret tls ords-tls -n "$NAMESPACE" --cert="$tls/tls.crt" --key="$tls/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$tls"
echo "Certificate: $(openssl x509 -in "$SSL_DIR/$CERT_FILE" -noout -subject -enddate | tr '\n' ' ')"

# 2. ORDS_PUBLIC_USER password
if ! kubectl get secret ords-db-runtime -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Enter the ORDS_PUBLIC_USER password the existing ORDS server uses (its pool's db.password)."
  secret_from_value ords-db-runtime ORACLE_USER_PWD "$(ask_password 'ORDS_PUBLIC_USER password')"
fi

# 3. Database connection details (not secret)
write_db_config() {
  kubectl create configmap ords-db -n "$NAMESPACE" \
    --from-literal=DB_HOST="$DB_HOST" --from-literal=DB_PORT="$DB_PORT" \
    --from-literal=DB_SERVICE="$DB_SERVICE" --from-literal=APEX_VERSION="$APEX_VERSION" \
    --dry-run=client -o yaml | kubectl apply -f -
}
write_db_config

# 4. Preflight: log in as ORDS_PUBLIC_USER and read the ORDS and APEX versions
#    (the first run also downloads the ORDS image, which takes a few minutes)
kubectl delete pod ords-preflight -n "$NAMESPACE" --ignore-not-found >/dev/null
render "$MANIFESTS/ords-preflight.yaml" | kubectl apply -f - >/dev/null
echo "Checking the database connection..."
for _ in $(seq 1 120); do
  phase=$(kubectl get pod ords-preflight -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 5
done
out=$(kubectl logs ords-preflight -n "$NAMESPACE" 2>&1 || true)
kubectl delete pod ords-preflight -n "$NAMESPACE" --ignore-not-found >/dev/null
if ! grep -q LOGIN_OK <<<"$out"; then
  echo "$out" | tail -20 >&2
  echo "Couldn't log in to $DB_HOST:$DB_PORT/$DB_SERVICE as ORDS_PUBLIC_USER (see above)." >&2
  echo "If the password is wrong: kubectl delete secret ords-db-runtime -n $NAMESPACE, then re-run." >&2
  exit 1
fi
db_ords=$(sed -n 's/^ORDS_VERSION=\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' <<<"$out" | head -1)
db_apex=$(sed -n 's/^APEX_VERSION=\([0-9]*\.[0-9]*\).*/\1/p' <<<"$out" | head -1)
echo "Logged in. ORDS in the database: ${db_ords:-not found}. APEX: ${db_apex:-not found}. ORDS image: $ORDS_TAG."

# 5. APEX images version
if [ -z "$APEX_VERSION" ] && [ -n "$db_apex" ]; then
  APEX_VERSION=$db_apex
fi
if [ -n "$APEX_VERSION" ]; then
  [ -z "$db_apex" ] || [ "$db_apex" = "$APEX_VERSION" ] \
    || echo "WARNING: APEX_VERSION=$APEX_VERSION but the database has APEX $db_apex."
  curl -fsI "https://download.oracle.com/otn_software/apex/apex_${APEX_VERSION}.zip" >/dev/null \
    || { echo "No APEX download for version $APEX_VERSION (apex_${APEX_VERSION}.zip)." >&2; exit 1; }
  write_db_config
  echo "Serving APEX $APEX_VERSION images at /i/"
else
  echo "WARNING: no APEX version found, so /i/ will have no APEX images."
fi

# 6. ORDS schema: must match the image, unless we install or upgrade it
if [ "$db_ords" != "$ORDS_TAG" ]; then
  if [ "$INSTALL_OR_UPGRADE_SCHEMA" != true ]; then
    echo "The database has ORDS ${db_ords:-not found} but ORDS_IMAGE is $ORDS_TAG." >&2
    echo "Either set ORDS_IMAGE to the database's version, or set INSTALL_OR_UPGRADE_SCHEMA=true" >&2
    echo "to install/upgrade the schema to $ORDS_TAG (then upgrade any other ORDS server too)." >&2
    exit 1
  fi
  echo "Enter the SYS password for $DB_HOST:$DB_PORT/$DB_SERVICE. It's used once and then deleted."
  secret_from_value ords-db-admin ORACLE_PWD "$(ask_password 'SYS password')"
  kubectl delete job ords-install -n "$NAMESPACE" --ignore-not-found
  render "$MANIFESTS/ords-install-job.yaml" | kubectl apply -f -
  echo "Installing ORDS $ORDS_TAG in the database..."
  if ! kubectl wait --for=condition=complete job/ords-install -n "$NAMESPACE" --timeout=30m; then
    kubectl logs job/ords-install -n "$NAMESPACE" --tail=50 || true
    kubectl delete secret ords-db-admin -n "$NAMESPACE" --ignore-not-found
    echo "The ORDS install failed; see the log above." >&2
    exit 1
  fi
  kubectl logs job/ords-install -n "$NAMESPACE" --tail=5
  kubectl delete secret ords-db-admin -n "$NAMESPACE"
  echo "Removed the SYS password from the cluster."
fi

# 7. ORDS settings and deployment
kubectl create configmap ords-settings -n "$NAMESPACE" --from-file="$K8S/config/ords-settings.conf" \
  --dry-run=client -o yaml | kubectl apply -f -
render "$MANIFESTS/ords.yaml" | kubectl apply -f -
kubectl rollout restart deployment/ords -n "$NAMESPACE"   # pick up changed settings or certificate
kubectl rollout status deployment/ords -n "$NAMESPACE" --timeout=20m
kubectl get pods,svc -n "$NAMESPACE" -o wide

resolved=$(getent hosts "$ORDS_HOSTNAME" | awk '{print $1}' | head -1 || true)
[ "$resolved" = "$LB_IP" ] \
  || echo "NOTE: $ORDS_HOSTNAME resolves to '${resolved:-nothing}'. Add a DNS record: $ORDS_HOSTNAME -> $LB_IP"
echo "ORDS is at https://$ORDS_HOSTNAME/apps/ (http:// redirects to https://)"
