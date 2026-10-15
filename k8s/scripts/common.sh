# shellcheck shell=bash
# Helpers shared by the k8s scripts. Sourced, not run; the caller sets K8S (the k8s/ folder).

UPSTREAM_PINS="$K8S/config/upstream.sha256"

# fetch_verified <url> <file>: download an upstream manifest and check it against its
# pinned SHA-256 in config/upstream.sha256, so only reviewed files reach the cluster
fetch_verified() {
  local want
  want=$(awk -v u="$1" '$2 == u {print $1}' "$UPSTREAM_PINS")
  [ -n "$want" ] || { echo "$1 isn't pinned in $UPSTREAM_PINS." >&2; return 1; }
  curl -fsSL "$1" -o "$2"
  echo "$want  $2" | sha256sum -c --quiet - \
    || { echo "$1 doesn't match its pinned SHA-256 in $UPSTREAM_PINS." >&2; return 1; }
}
