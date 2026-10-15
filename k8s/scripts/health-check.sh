#!/usr/bin/env bash
# Check the cluster and ORDS, print one line per check, and exit 1 if any check fails.
# Run on k8-control as root: sudo ./health-check.sh
# Schedule it from a root-owned copy, like etcd-backup.sh (README, Appendix C.2):
#   sudo install -m 0755 k8s/scripts/health-check.sh /usr/local/sbin/k8s-health-check.sh
#   echo '*/15 * * * * root /usr/local/sbin/k8s-health-check.sh >/dev/null' | sudo tee /etc/cron.d/k8s-health-check
# Results also go to the system log (journalctl -t k8s-health). If HEALTHCHECK_URL is set, in
# /etc/default/k8s-health-check, each run reports to that monitoring service (for example
# https://hc-ping.com/<uuid> from healthchecks.io): it alerts you when a run fails, and when runs
# stop arriving, which covers k8-control itself being down.
set -uo pipefail

NAMESPACE=ords                    # production, as in k8s/portal/prod (ci/validate.sh checks
ORDS_HOSTNAME=www.1apx.com        # these three against its kustomization.yaml and ords.env)
LB_IP=192.168.1.180
NODES="k8-control k8-worker-1 k8-worker-2"
WARN_DAYS=30                      # certificates expiring within this many days fail the check
DISK_MAX=85                       # % used on any node's root filesystem
BACKUP_DIR=/var/backups/kubernetes
BACKUP_MAX_HOURS=26               # the newest etcd backup must be younger (daily cron at 02:30)
HEALTHCHECK_URL=
# shellcheck disable=SC1091
[ -r /etc/default/k8s-health-check ] && . /etc/default/k8s-health-check
export KUBECONFIG=/etc/kubernetes/admin.conf

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
failed=0 report=
result() {  # result ok|FAIL <message>
  report+="$1  $2"$'\n'
  [ "$1" = ok ] || failed=1
}

# Nodes: each one Ready, with no memory, disk or process pressure
for n in $NODES; do
  conds=$(kubectl get node "$n" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null)
  if [ -z "$conds" ]; then result FAIL "node $n: not found or API unreachable"
  elif [[ " $conds" != *" Ready "* ]]; then result FAIL "node $n: not Ready"
  elif [ "$conds" != "Ready " ]; then c=${conds/Ready /}; result FAIL "node $n: ${c% }"
  else result ok "node $n: Ready"; fi
done

# ORDS: every pod ready, and answering
want=$(kubectl get deployment ords -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
ready=$(kubectl get deployment ords -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [ -n "$want" ] && [ "${ready:-0}" -ge "$want" ]; then result ok "ORDS: $ready of $want pods ready"
else result FAIL "ORDS: ${ready:-0} of ${want:-?} pods ready"; fi
direct() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$ORDS_HOSTNAME:443:$LB_IP" "https://$ORDS_HOSTNAME$1"; }
code=$(direct /apps/_/landing)
if [ "$code" = 200 ]; then result ok "ORDS answers at $LB_IP and reaches the database"
else result FAIL "ORDS at $LB_IP: /apps/_/landing answered '$code' (200 expected; 571 means no database)"; fi

# Certificates: the one ORDS serves, and the cluster's own (kubeadm)
end=$(echo | openssl s_client -connect "$LB_IP:443" -servername "$ORDS_HOSTNAME" 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -z "$end" ]; then result FAIL "ORDS certificate: couldn't read it from $LB_IP:443"
else
  days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
  if [ "$days" -ge "$WARN_DAYS" ]; then result ok "ORDS certificate: expires in $days days"
  else result FAIL "ORDS certificate: expires in $days days ($end)"; fi
fi
# Certificates (not CAs) in "kubeadm certs check-expiration" with less than WARN_DAYS left. Its
# RESIDUAL TIME column reads like 2y, 364d, 5h, 40m or 30s, and <invalid> once expired.
soon=$(kubeadm certs check-expiration 2>/dev/null | awk -v w="$WARN_DAYS" '
  /^CERTIFICATE AUTHORITY/ {exit}
  { for (i = 2; i <= NF; i++) if ($i ~ /^([0-9]+[smhdy]|<invalid>)$/) {
      if ($i == "<invalid>" || $i ~ /[smh]$/ || ($i ~ /d$/ && $i + 0 < w)) print $1; break } }' | xargs)
if kubeadm certs check-expiration >/dev/null 2>&1; then
  if [ -z "$soon" ]; then result ok "cluster certificates: none expire within $WARN_DAYS days"
  else result FAIL "cluster certificates expiring within $WARN_DAYS days: $soon (renew: kubeadm certs renew all)"; fi
else result FAIL "cluster certificates: kubeadm certs check-expiration failed"; fi

# Disk space on every node's root filesystem (from kubelet's stats)
for n in $NODES; do
  pct=$(kubectl get --raw "/api/v1/nodes/$n/proxy/stats/summary" 2>/dev/null | python3 -c '
import json, sys
fs = json.load(sys.stdin)["node"]["fs"]
print(round(100 * fs["usedBytes"] / fs["capacityBytes"]))' 2>/dev/null)
  if [ -z "$pct" ]; then result FAIL "disk on $n: couldn't read kubelet's stats"
  elif [ "$pct" -le "$DISK_MAX" ]; then result ok "disk on $n: $pct% used"
  else result FAIL "disk on $n: $pct% used (over $DISK_MAX%)"; fi
done

# etcd backups: a recent one exists
newest=$(find "$BACKUP_DIR" -maxdepth 1 -name 'etcd-*.db' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
if [ -z "$newest" ]; then result FAIL "etcd backup: none in $BACKUP_DIR"
else
  age=$(( ($(date +%s) - ${newest%.*}) / 3600 ))
  if [ "$age" -lt "$BACKUP_MAX_HOURS" ]; then result ok "etcd backup: newest is $age hours old"
  else result FAIL "etcd backup: newest is $age hours old"; fi
fi

printf '%s' "$report"
summary="$( [ "$failed" = 0 ] && echo "all checks passed" || echo "FAILED: $(grep -c '^FAIL' <<<"$report") check(s)" )"
logger -t k8s-health -- "$summary"
[ "$failed" = 0 ] || grep '^FAIL' <<<"$report" | logger -t k8s-health -p user.err
if [ -n "$HEALTHCHECK_URL" ]; then
  url=$HEALTHCHECK_URL; [ "$failed" = 0 ] || url="$HEALTHCHECK_URL/fail"
  curl -fsS -m 10 --retry 3 --data-binary "$report" "$url" >/dev/null \
    || echo "Couldn't report to HEALTHCHECK_URL." >&2
fi
echo "$summary"
exit "$failed"
