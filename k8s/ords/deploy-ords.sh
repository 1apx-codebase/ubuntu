#!/usr/bin/env bash
# Deploy Oracle REST Data Services (ORDS) to the cluster.
# Run on k8-control as vaviles after cluster-addons.sh: ./deploy-ords.sh
# Safe to re-run; re-running with a newer ORDS_IMAGE upgrades ORDS.
set -euo pipefail

NAMESPACE=ords
ORDS_IMAGE=container-registry.oracle.com/database/ords:26.2.3
LB_IP=192.168.1.180               # from the MetalLB range in cluster-addons.sh

# Existing Oracle database ORDS connects to. It must be reachable from the workers.
DB_HOST=CHANGE_ME                 # hostname or IP of the database server
DB_PORT=1521
DB_SERVICE=CHANGE_ME              # the PDB service name, not the CDB

# Remove the SYS password from the cluster once ORDS is installed
DELETE_ADMIN_SECRET=true

HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -ne 0 ] || { echo "Run as vaviles, not root." >&2; exit 1; }
[ "$DB_HOST" != CHANGE_ME ] && [ "$DB_SERVICE" != CHANGE_ME ] || { echo "Set DB_HOST and DB_SERVICE at the top of this script." >&2; exit 1; }
render() { sed -e "s|__ORDS_IMAGE__|$ORDS_IMAGE|g" -e "s|__LB_IP__|$LB_IP|g" "$1"; }

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

# 1. Secrets
if ! kubectl get secret ords-db-runtime -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Choose a password for ORDS_PUBLIC_USER (the account ORDS connects as)."
  secret_from_value ords-db-runtime ORACLE_USER_PWD "$(ask_password 'ORDS_PUBLIC_USER password')"
fi
if ! kubectl get secret ords-db-admin -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Enter the SYS password for $DB_HOST:$DB_PORT/$DB_SERVICE (used once, to install ORDS)."
  secret_from_value ords-db-admin ORACLE_PWD "$(ask_password 'SYS password')"
fi

# 2. Check the database is reachable from inside the cluster
# (uses the ORDS image, which also pulls it before the install job needs it)
kubectl delete pod ords-dbcheck -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl run ords-dbcheck -n "$NAMESPACE" --rm -i --restart=Never --quiet --pod-running-timeout=10m \
  --image="$ORDS_IMAGE" --command -- bash -c "timeout 5 bash -c '</dev/tcp/$DB_HOST/$DB_PORT'" \
  || { echo "Can't reach $DB_HOST:$DB_PORT from the cluster (DNS, firewall or listener)." >&2; exit 1; }
echo "Database listener $DB_HOST:$DB_PORT is reachable"

# 3. Database connection details (not secret)
kubectl create configmap ords-db -n "$NAMESPACE" \
  --from-literal=DB_HOST="$DB_HOST" --from-literal=DB_PORT="$DB_PORT" --from-literal=DB_SERVICE="$DB_SERVICE" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Install or upgrade the ORDS schema in the database
if kubectl get secret ords-db-admin -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl delete job ords-install -n "$NAMESPACE" --ignore-not-found
  render "$HERE/ords-install-job.yaml" | kubectl apply -f -
  echo "Installing ORDS in the database..."
  if ! kubectl wait --for=condition=complete job/ords-install -n "$NAMESPACE" --timeout=30m; then
    kubectl logs job/ords-install -n "$NAMESPACE" --tail=50 || true
    echo "The ORDS install failed; see the log above." >&2
    exit 1
  fi
  kubectl logs job/ords-install -n "$NAMESPACE" --tail=5
  if [ "$DELETE_ADMIN_SECRET" = true ]; then
    kubectl delete secret ords-db-admin -n "$NAMESPACE"
    echo "Removed the SYS password from the cluster. The next upgrade will ask for it again."
  fi
else
  echo "No SYS password in the cluster, so skipping the schema install (re-run to be asked for it)."
fi

# 5. ORDS itself
render "$HERE/ords.yaml" | kubectl apply -f -
kubectl rollout restart deployment/ords -n "$NAMESPACE"
kubectl rollout status deployment/ords -n "$NAMESPACE" --timeout=15m
kubectl get pods,svc -n "$NAMESPACE" -o wide
echo "ORDS is at http://$LB_IP/ords/"
