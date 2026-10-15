#!/usr/bin/env bash
# Validate the whole repo: scripts, Kubernetes manifests, values that must agree across
# files, pinned upstream downloads, file hygiene, and secrets in the git history.
# Run from anywhere: ci/validate.sh [--offline]. GitHub Actions runs it on every push.
# --offline skips the checks that need the internet (upstream hashes, Calico's file,
# Cloudflare's ranges); it needs one online run first, to fill the tool and schema cache.
# Tools are downloaded once, checked against pinned SHA-256s, into ~/.cache/ubuntu-repo-tools.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
K8S=$ROOT/k8s
TOOLS=${XDG_CACHE_HOME:-$HOME/.cache}/ubuntu-repo-tools
ONLINE=true
[ "${1:-}" = --offline ] && ONLINE=false
cd "$ROOT"

failed=0
pass() { echo "ok    $*"; }
note() { echo "note  $*"; }        # worth knowing, but not a failure
fail() { echo "FAIL  $*" >&2; failed=1; }
# check <description> <command...>: run a check and report it
check() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
# var <file> <name>: a NAME=value line's value, without its comment
var() { sed -n "s/^$2=\([^ ]*\).*/\1/p" "$1" | head -1; }

# tool <name> <url> <sha256>: path to a pinned, checksum-verified tool binary
tool() {
  local dir="$TOOLS/$1-${3:0:12}" f
  if [ ! -x "$dir/$1" ]; then
    rm -rf "$dir" && mkdir -p "$dir/x"
    f="$dir/download"
    curl -fsSL "$2" -o "$f"
    echo "$3  $f" | sha256sum -c --quiet - || { echo "$2 doesn't match its pinned SHA-256" >&2; exit 1; }
    case "$2" in
      *.tar.gz) tar -xzf "$f" -C "$dir/x" ;;
      *.tar.xz) tar -xJf "$f" -C "$dir/x" ;;
      *)        cp "$f" "$dir/x/$1" ;;
    esac
    install -m 0755 "$(find "$dir/x" -type f -name "$1" | head -1)" "$dir/$1"
    rm -rf "$dir/x" "$f"
  fi
  echo "$dir/$1"
}

K8S_VERSION=$(var "$K8S/scripts/node-prep.sh" K8S_VERSION)
SHELLCHECK=$(tool shellcheck https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198)
KUBECONFORM=$(tool kubeconform https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz 9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883)
GITLEAKS=$(tool gitleaks https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb)
# kubeadm and kubectl (whose built-in Kustomize builds the overlays) in the version the
# cluster uses (node-prep.sh), checked against Kubernetes' published hash on first use and
# then cached per version
k8s_bin() {
  local dir="$TOOLS/$1-v$K8S_VERSION" url="https://dl.k8s.io/release/v$K8S_VERSION/bin/linux/amd64/$1"
  if [ ! -x "$dir/$1" ]; then
    mkdir -p "$dir"
    curl -fsSL "$url" -o "$dir/download"
    echo "$(curl -fsSL "$url.sha256")  $dir/download" | sha256sum -c --quiet - \
      || { echo "$url doesn't match its published SHA-256" >&2; exit 1; }
    install -m 0755 "$dir/download" "$dir/$1" && rm -f "$dir/download"
  fi
  echo "$dir/$1"
}
KUBEADM=$(k8s_bin kubeadm)
KUBECTL=$(k8s_bin kubectl)
# Arimo (Arial's metrics) for docs/architecture.py, pinned to a google/fonts commit
ARIMO=$(tool arimo.ttf https://raw.githubusercontent.com/google/fonts/d7b3b07542b00e0ec7c48886d305eb8f08ef89d5/ofl/arimo/Arimo%5Bwght%5D.ttf e43898b143ec826ac8cb4034816458a7047fbe0836558de2a1f8c6223ae3e0ca)
python3 -c 'import yaml' 2>/dev/null || { echo "Needs Python's yaml module (apt install python3-yaml)." >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mapfile -t SCRIPTS < <(git ls-files '*.sh')

echo "== Shell scripts"
for f in "${SCRIPTS[@]}"; do
  bash -n "$f" || fail "bash -n $f"
done
check "shellcheck: ${#SCRIPTS[@]} scripts" "$SHELLCHECK" -x -P SCRIPTDIR "${SCRIPTS[@]}"
# Every script is executable, except common.sh, which is only sourced
while read -r mode _ _ f; do
  [ "$f" = k8s/scripts/common.sh ] && continue
  [ "$mode" = 100755 ] || fail "$f is not executable in git (git update-index --chmod=+x $f)"
done < <(git ls-files -s '*.sh')

echo "== Kubernetes manifests"
mkdir -p "$work/rendered"
# Every portal environment with a kustomization.yaml, built as deploy-ords.sh builds it
# (common -> portal/base -> portal/<env>). An environment that isn't set up yet holds only
# its README.md.
envs=()
for d in "$K8S"/portal/*/; do
  e=$(basename "$d")
  [ "$e" = base ] && continue
  if [ -f "$d/kustomization.yaml" ]; then
    envs+=("$e")
  elif [ "$(ls -A "$d")" = README.md ]; then
    pass "portal/$e: placeholder, not set up yet"
  else
    fail "portal/$e has files but no kustomization.yaml"
  fi
done
[ "${#envs[@]}" -gt 0 ] || fail "no portal environment has a kustomization.yaml"
build() { "$KUBECTL" kustomize "$K8S/portal/$1" > "$work/rendered/$1.yaml"; }
for e in "${envs[@]}"; do
  check "kustomize build: portal/$e" build "$e"
  # Every "set by the environment" placeholder in the base must have been replaced
  if grep -nE 'set-by-environment|192\.0\.2\.1' "$work/rendered/$e.yaml"; then fail "portal/$e: placeholders left (above)"; fi
  [ -n "$(sed -n 's/^DB_IP=//p' "$K8S/portal/$e/ords.env")" ] \
    || note "portal/$e: DB_IP in ords.env isn't set yet; deploy-ords.sh needs it"
done
# CRD schemas (MetalLB, Calico) from datreeio/CRDs-catalog, pinned to a commit
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/63669a570e231d4f1f8396d229a1de512bcf0a34/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# Schemas are cached, so later runs (and --offline) don't need to download them
mkdir -p "$TOOLS/kubeconform-cache"
KUBECONFORM=("$KUBECONFORM" -cache "$TOOLS/kubeconform-cache")
check "kubeconform: portal environments (Kubernetes $K8S_VERSION schemas)" "${KUBECONFORM[@]}" -strict -summary \
  -kubernetes-version "$K8S_VERSION" -schema-location default "$work"/rendered/*.yaml
# MetalLB's resources are CRDs: only the CRD catalog has their schemas (asking the default
# location first would fail offline instead of falling through to the cached catalog)
check "kubeconform: MetalLB pool (CRD schemas)" "${KUBECONFORM[@]}" -strict -summary \
  -schema-location "$CRDS" "$K8S"/manifests/addons/*.yaml
if "$KUBEADM" config validate --config "$K8S/manifests/kubeadm-config.yaml" >/dev/null; then
  pass "kubeadm $K8S_VERSION config validate"
else
  fail "kubeadm config validate"
fi
# The audit policy has no published schema: check its shape and that every rule has a level
if python3 - "$K8S/manifests/audit-policy.yaml" <<'PY'; then pass "audit policy"; else fail "audit policy"; fi
import sys, yaml
p = yaml.safe_load(open(sys.argv[1]))
assert p["apiVersion"] == "audit.k8s.io/v1" and p["kind"] == "Policy", "not an audit.k8s.io/v1 Policy"
levels = {"None", "Metadata", "Request", "RequestResponse"}
assert p["rules"] and all(r.get("level") in levels for r in p["rules"]), "a rule has no valid level"
PY
# Pod Security "restricted", which namespace.yaml enforces: the same rules the API server applies
# (https://kubernetes.io/docs/concepts/security/pod-security-standards/), so a violation shows up
# here rather than as pods that are never created. Also: every root filesystem is read-only.
if python3 - "$work"/rendered/*.yaml <<'PY'; then pass "every pod meets Pod Security restricted, with read-only root filesystems"; else fail "Pod Security restricted (above)"; fi
import sys, yaml
ALLOWED_VOLUMES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"}
bad = []
for f in sys.argv[1:]:
    for d in yaml.safe_load_all(open(f)):
        if not d or d["kind"] not in ("Deployment", "Pod", "Job"):
            continue
        spec = d["spec"] if d["kind"] == "Pod" else d["spec"]["template"]["spec"]
        name = f"{d['kind']}/{d['metadata']['name']}"
        psc = spec.get("securityContext", {})
        for k in ("hostNetwork", "hostPID", "hostIPC"):
            if spec.get(k): bad.append(f"{name}: {k}")
        for v in spec.get("volumes", []):
            t = (set(v) - {"name"}).pop()
            if t not in ALLOWED_VOLUMES: bad.append(f"{name}: volume {v['name']} is {t}")
        if psc.get("runAsUser") == 0: bad.append(f"{name}: runAsUser 0")
        for c in spec.get("initContainers", []) + spec["containers"]:
            sc, cn = c.get("securityContext", {}), f"{name}/{c['name']}"
            caps = sc.get("capabilities", {})
            if sc.get("privileged"): bad.append(f"{cn}: privileged")
            if sc.get("allowPrivilegeEscalation") is not False: bad.append(f"{cn}: allowPrivilegeEscalation not false")
            if not sc.get("runAsNonRoot", psc.get("runAsNonRoot")): bad.append(f"{cn}: runAsNonRoot not true")
            if sc.get("runAsUser") == 0: bad.append(f"{cn}: runAsUser 0")
            if sc.get("seccompProfile", psc.get("seccompProfile", {})).get("type") not in ("RuntimeDefault", "Localhost"):
                bad.append(f"{cn}: no RuntimeDefault or Localhost seccomp profile")
            if "ALL" not in caps.get("drop", []): bad.append(f"{cn}: capabilities not dropped (ALL)")
            if set(caps.get("add", [])) - {"NET_BIND_SERVICE"}: bad.append(f"{cn}: adds capabilities {caps['add']}")
            if any(p.get("hostPort") for p in c.get("ports", [])): bad.append(f"{cn}: hostPort")
            if sc.get("readOnlyRootFilesystem") is not True: bad.append(f"{cn}: root filesystem not read-only")
for b in bad:
    print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
# Bash embedded in the manifests
if python3 - "$work"/rendered/*.yaml <<'PY'; then pass "bash -n on the scripts in the manifests"; else fail "embedded scripts"; fi
import subprocess, sys, yaml
bad = 0
for f in sys.argv[1:]:
    for d in yaml.safe_load_all(open(f)):
        if not d or d["kind"] not in ("Deployment", "Pod", "Job"):
            continue
        spec = d["spec"] if d["kind"] == "Pod" else d["spec"]["template"]["spec"]
        for c in spec.get("initContainers", []) + spec["containers"]:
            if c.get("command", [])[:2] == ["/bin/bash", "-c"]:
                r = subprocess.run(["bash", "-n"], input=c["args"][0], text=True, capture_output=True)
                if r.returncode:
                    print(f"{d['kind']}/{c['name']}: {r.stderr}", file=sys.stderr); bad = 1
sys.exit(bad)
PY

echo "== Values that must agree across files"
same() {  # same <description> <value> <value>...
  local d=$1 v=$2; shift 2
  [ -n "$v" ] || { fail "$d: couldn't read the value"; return; }
  for x in "$@"; do [ "$x" = "$v" ] || { fail "$d differs: '$v' vs '$x'"; return; }; done
  pass "$d: $v"
}
kubeadm_cfg="$K8S/manifests/kubeadm-config.yaml"
hosts=$(sed -n '/^HOSTS_BLOCK="/,/"$/p' "$K8S/scripts/node-prep.sh" | tr -d '"' | sed 's/^HOSTS_BLOCK=//')
host_ip() { awk -v h="$1" '$3 == h {print $1}' <<<"$hosts"; }
same "Kubernetes version" "v$K8S_VERSION" "$(sed -n 's/^kubernetesVersion: //p' "$kubeadm_cfg")"
same "Kubernetes package channel" "v${K8S_VERSION%.*}" "$(var "$K8S/scripts/node-prep.sh" K8S_MINOR)"
same "Pod CIDR" "$(var "$K8S/scripts/node-prep.sh" POD_CIDR)" \
  "$(var "$K8S/scripts/control-plane-init.sh" POD_CIDR)" "$(sed -n 's/^ *podSubnet: //p' "$kubeadm_cfg")"
same "k8-control IP" "$(host_ip k8-control)" "$(sed -n 's/^ *advertiseAddress: //p' "$kubeadm_cfg")" \
  "$(var "$ROOT/apply-changes.sh" ADDR | cut -d/ -f1)"
same "Encryption config path" "$(var "$K8S/scripts/control-plane-init.sh" ENC_DIR)/encryption-config.yaml" \
  "$(grep -A1 'name: encryption-provider-config' "$kubeadm_cfg" | sed -n 's/^ *value: //p')"
for w in k8-worker-1 k8-worker-2; do
  same "$w IP" "$(host_ip "$w")" "$(grep -o "[0-9]* $w [0-9.]*" "$K8S/scripts/proxmox-create-workers.sh" | awk '{print $3}')"
done
dns_sorted() { tr ', ' '\n' <<<"$1" | grep . | sort | xargs; }
same "DNS servers" "$(dns_sorted "$(sed -n 's/^DNS_SERVERS="\([^"]*\)".*/\1/p' "$K8S/scripts/node-prep.sh")")" \
  "$(dns_sorted "$(sed -n 's/^DNS="\([^"]*\)".*/\1/p' "$K8S/scripts/proxmox-create-workers.sh")")" \
  "$(dns_sorted "$(sed -n 's/^DNS="\([^"]*\)".*/\1/p' "$ROOT/apply-changes.sh")")"
# The personal login (<user> in the README), set separately in each script that needs it
same "Personal login" "$(var "$ROOT/apply-changes.sh" USER_NAME)" "$(var "$ROOT/revert-changes.sh" USER_NAME)" \
  "$(sed -n 's/^KUBECONFIG_USERS="\([^ "]*\).*/\1/p' "$K8S/scripts/control-plane-init.sh")" \
  "$(var "$K8S/scripts/proxmox-create-workers.sh" CONTROL_LOGIN | cut -d@ -f1)" \
  "$(sed -n 's|^ *\([^:]*\):/home/\1/\.claude/settings\.json$|\1|p' "$ROOT/claude-classic-tui.sh")"
# The namespace's Pod Security version is the cluster's minor version
mapfile -t psa_versions < <(sed -n 's/^ *pod-security\.kubernetes\.io\/[a-z]*-version: //p' "$K8S/common/namespace.yaml")
[ "${#psa_versions[@]}" = 3 ] || fail "namespace.yaml should have 3 Pod Security version labels, has ${#psa_versions[@]}"
same "Pod Security version labels" "v${K8S_VERSION%.*}" "${psa_versions[@]}"
# Per environment: its LoadBalancer IP inside MetalLB's pool (and no two environments sharing
# one), its database port the same in ords.env and the network policy, and every image pinned
# by tag and digest
range=$(sed -n 's/^ *- \([0-9.]*-[0-9.]*\)$/\1/p' "$K8S/manifests/addons/metallb-pool.yaml")
lb_ips=()
for e in "${envs[@]}"; do
  lb_ip=$(sed -n 's/^LB_IP=//p' "$K8S/portal/$e/ords.env")
  lb_ips+=("$lb_ip")
  check "portal/$e: LB_IP $lb_ip within the MetalLB pool $range" python3 -c 'import ipaddress as i, sys
a, b = sys.argv[2].split("-")
sys.exit(not i.ip_address(a) <= i.ip_address(sys.argv[1]) <= i.ip_address(b))' "$lb_ip" "$range"
  same "portal/$e: database port in ords.env and the network policy" \
    "$(sed -n 's/^DB_PORT=//p' "$K8S/portal/$e/ords.env")" \
    "$(python3 -c 'import sys, yaml
print([d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "ords"][0]["spec"]["egress"][0]["ports"][0]["port"])' "$work/rendered/$e.yaml")"
  if grep -E '^ *image: ' "$work/rendered/$e.yaml" | grep -vqE 'image: [^ ]+:[^ @]+@sha256:[0-9a-f]{64}$'; then
    fail "portal/$e: an image isn't pinned by tag and digest (images: in its kustomization.yaml)"
  else
    pass "portal/$e: every image pinned by tag and digest"
  fi
done
[ "$(printf '%s\n' "${lb_ips[@]}" | sort | uniq -d)" = "" ] || fail "two environments share a LB_IP"
# health-check.sh checks production with its own copy of production's values
hc="$K8S/scripts/health-check.sh" prod="$K8S/portal/prod"
same "health-check.sh namespace" "$(sed -n 's/^namespace: *//p' "$prod/kustomization.yaml")" "$(var "$hc" NAMESPACE)"
same "health-check.sh host name" "$(sed -n 's/^ORDS_HOSTNAME=//p' "$prod/ords.env")" "$(var "$hc" ORDS_HOSTNAME)"
same "health-check.sh MetalLB address" "$(sed -n 's/^LB_IP=//p' "$prod/ords.env")" "$(var "$hc" LB_IP)"

# Besides Cloudflare, the ORDS Service admits exactly the three nodes (each as a /32), never a
# wider LAN range: a router that rewrites forwarded connections' source would get past one
ranges=$(sed -n '/loadBalancerSourceRanges:/,/^  [a-zA-Z]/p' "$K8S/portal/base/service.yaml" \
  | grep -oE '[0-9]+\.[0-9.]+/[0-9]+' | sort)
same "LAN addresses the ORDS Service admits (the nodes)" \
  "$(awk '{print $1 "/32"}' <<<"$hosts" | sort | xargs)" "$(grep '^192\.168\.' <<<"$ranges" | xargs)"

echo "== Pinned upstream manifests (k8s/config/upstream.sha256)"
pins="$K8S/config/upstream.sha256"
calico=$(var "$K8S/scripts/control-plane-init.sh" CALICO_VERSION)
metallb=$(var "$K8S/scripts/cluster-addons.sh" METALLB_VERSION)
metrics=$(var "$K8S/scripts/cluster-addons.sh" METRICS_SERVER_VERSION)
expected=(
  "https://raw.githubusercontent.com/projectcalico/calico/$calico/manifests/operator-crds.yaml"
  "https://raw.githubusercontent.com/projectcalico/calico/$calico/manifests/tigera-operator.yaml"
  "https://raw.githubusercontent.com/projectcalico/calico/$calico/manifests/custom-resources.yaml"
  "https://raw.githubusercontent.com/metallb/metallb/$metallb/config/manifests/metallb-native.yaml"
  "https://github.com/kubernetes-sigs/metrics-server/releases/download/$metrics/components.yaml"
)
ok=true
for u in "${expected[@]}"; do
  awk -v u="$u" '$2 == u {f=1} END {exit !f}' "$pins" || { fail "not pinned: $u"; ok=false; }
done
[ "$(grep -cv '^#' "$pins")" = "${#expected[@]}" ] || { fail "$pins has entries the scripts don't use"; ok=false; }
[ "$ok" = false ] || pass "every upstream manifest the scripts use is pinned, and nothing else"
if [ "$ONLINE" = true ]; then
  ok=true
  while read -r sum u; do
    f="$work/upstream-$(basename "$u")"   # kept for the checks below once verified
    if ! curl -fsSL "$u" -o "$f" || ! echo "$sum  $f" | sha256sum -c --quiet - 2>/dev/null; then
      fail "upstream doesn't match its pinned hash (or can't be downloaded): $u"; ok=false; rm -f "$f"
    fi
  done < <(grep -v '^#' "$pins")
  [ "$ok" = false ] || pass "pinned hashes match upstream"
  # The scripts' edits to the upstream files, made the same way on the verified copies
  cr="$work/upstream-custom-resources.yaml" ms="$work/upstream-components.yaml"
  if [ -f "$cr" ] && [ -f "$ms" ]; then
    # Calico's Installation with our pod CIDR, as control-plane-init.sh applies it
    pod_cidr=$(var "$K8S/scripts/node-prep.sh" POD_CIDR)
    sed "s|cidr: 192.168.0.0/16|cidr: $pod_cidr|" "$cr" \
      | python3 -c 'import sys,yaml; print(yaml.safe_dump_all([d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] == "Installation"]))' \
      > "$work/calico-installation.yaml"
    check "Calico's pod CIDR is replaced, as control-plane-init.sh does" grep -q "cidr: $pod_cidr" "$work/calico-installation.yaml"
    check "Calico Installation with our pod CIDR" "${KUBECONFORM[@]}" -strict -kubernetes-version "$K8S_VERSION" \
      -schema-location default -schema-location "$CRDS" "$work/calico-installation.yaml"
    # metrics-server gets --kubelet-insecure-tls with the same sed as cluster-addons.sh
    sed -i "$(grep -o "sed -i '[^']*'" "$K8S/scripts/cluster-addons.sh" | head -1 | sed "s/^sed -i '//; s/'$//")" "$ms"
    check "metrics-server gets --kubelet-insecure-tls, as cluster-addons.sh does" grep -q -- '- --kubelet-insecure-tls$' "$ms"
  else
    fail "couldn't check the scripts' edits to Calico's and metrics-server's files (download failed, above)"
  fi
  # The ORDS Service admits Cloudflare's current IPv4 ranges (plus the nodes), no more, no less
  cf_live=$(curl -fsSL https://www.cloudflare.com/ips-v4 | grep -oE '^[0-9.]+/[0-9]+' | sort || true)
  cf_repo=$(grep -v '^192\.168\.' <<<"$ranges" || true)
  if [ -n "$cf_live" ] && [ "$cf_live" = "$cf_repo" ]; then
    pass "ORDS Service allows exactly Cloudflare's current IPv4 ranges"
  else
    fail "Cloudflare's IPv4 ranges changed, or couldn't be downloaded: compare loadBalancerSourceRanges in k8s/portal/base/service.yaml with https://www.cloudflare.com/ips-v4"
  fi
fi

echo "== Documentation"
# Relative links in the README point at files that exist, and #anchors at real headings
if python3 - README.md <<'PY'; then pass "README links and anchors"; else fail "README links and anchors"; fi
import os, re, sys
md = open(sys.argv[1]).read()
def slug(h):
    return re.sub(r"[^\w\- ]", "", h.replace("`", "").strip().lower()).replace(" ", "-")
anchors = {slug(h) for h in re.findall(r"^#{1,6} (.+)$", md, re.M)}
bad = 0
for target in re.findall(r"\]\(([^)\s]+)\)", md):
    if target.startswith(("http://", "https://", "mailto:")):
        continue
    path, _, frag = target.partition("#")
    if path and not os.path.exists(path):
        print(f"missing file: {target}", file=sys.stderr); bad = 1
    elif not path and frag not in anchors:
        print(f"missing heading: {target}", file=sys.stderr); bad = 1
sys.exit(bad)
PY
# The README's Contents lists every ## and ### heading, in order, with the right nesting
if python3 - README.md <<'PY'; then pass "README Contents matches its headings"; else fail "README Contents is out of date"; fi
import re, sys
md = open(sys.argv[1]).read()
def slug(h):
    return re.sub(r"[^\w\- ]", "", h.replace("`", "").strip().lower()).replace(" ", "-")
toc_block = md.split("## Contents\n", 1)[1].split("\n## ", 1)[0]
toc = re.findall(r"^( *)- \[(.+)\]\(#([^)]+)\)$", toc_block, re.M)
body = md.split("## Contents\n", 1)[1].split("\n", 1)[1]
heads = [(lvl, t) for lvl, t in re.findall(r"^(##|###) (.+)$", body, re.M)]
want = [("" if lvl == "##" else "  ", t, slug(t)) for lvl, t in heads]
if toc != want:
    for got, exp in zip(toc + [None] * len(want), want + [None] * len(toc)):
        if got != exp:
            print(f"first difference: Contents has {got}, headings say {exp}", file=sys.stderr)
            break
    sys.exit(1)
PY
# The diagram is generated: the committed SVG must be exactly what the script produces
if python3 docs/architecture.py "$work/architecture.svg" "$ARIMO" >/dev/null \
   && cmp -s "$work/architecture.svg" docs/architecture.svg; then
  pass "docs/architecture.svg matches docs/architecture.py, whose layout checks pass"
else
  fail "docs/architecture.svg is out of date, or its layout checks fail (see docs/architecture.py)"
fi

echo "== File hygiene"
mapfile -t TEXT < <(git ls-files | grep -vE '\.(png|jpg|zip|tar|gz)$')
if grep -lI $'\r' "${TEXT[@]}"; then fail "CRLF line endings (above)"; else pass "LF line endings"; fi
if grep -nIE '[[:space:]]+$' "${TEXT[@]}" | grep -v '\.md:'; then fail "trailing whitespace (above)"; else pass "no trailing whitespace"; fi
ok=true
for f in "${TEXT[@]}"; do [ -z "$(tail -c1 "$f")" ] || { fail "$f doesn't end with a newline"; ok=false; }; done
[ "$ok" = false ] || pass "files end with a newline"

echo "== Secrets"
if "$GITLEAKS" git --no-banner --redact "$ROOT" >/dev/null 2>&1; then
  pass "gitleaks: no secrets in the git history"
else
  "$GITLEAKS" git --no-banner --redact -v "$ROOT" >&2 || true
  fail "gitleaks found secrets in the git history"
fi
# The files staged for the next commit (git's index), so a secret is caught before it's
# committed. Only tracked and staged files: the git-ignored ssl/ folder isn't scanned.
git checkout-index -a -f --prefix="$work/staged/"
if "$GITLEAKS" dir --no-banner --redact "$work/staged" >/dev/null 2>&1; then
  pass "gitleaks: no secrets in the files staged for commit"
else
  "$GITLEAKS" dir --no-banner --redact -v "$work/staged" >&2 || true
  fail "gitleaks found secrets in the files staged for commit"
fi
if git ls-files | grep -E '(^|/)ssl/|\.(key|pem|p12|jks|pfx)$|kubeconfig|admin\.conf'; then
  fail "key, certificate or kubeconfig files are tracked (above)"
else
  pass "no key, certificate or kubeconfig files tracked"
fi

echo
if [ "$failed" != 0 ]; then echo "Some checks FAILED." >&2; exit 1; fi
echo "All checks passed."
