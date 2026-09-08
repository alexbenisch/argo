#!/usr/bin/env bash
# Shared config + helpers. Source this, don't execute it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SERVER_NAME="argo-playground"
# cpx32 = x86, 4 vCPU / 8 GB / 160 GB. (The older cpx31 has identical specs but
# is retired in the EU locations and can no longer be ordered.)
SERVER_TYPE="cpx32"
SERVER_IMAGE="ubuntu-24.04"
SERVER_LOCATION="nbg1"
FIREWALL_NAME="argo-playground-fw"
SSH_KEY_NAME="argo-playground"
SSH_KEY_PATH="$HOME/.ssh/argo-playground"

CF_ZONE_ID="0586507fe8e0c8bef795eb0d82b77cde"
CF_ZONE_NAME="kubetest.uk"
ARGOCD_HOST="argo.kubetest.uk"
ARGOWF_HOST="argo-wf.kubetest.uk"

KUBE_CONTEXT="argo-playground"
APISERVER_PORT="6443"

# Email for Let's Encrypt registration
ACME_EMAIL="alexander.benisch@gmail.com"

# ---------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

load_env() {
  [ -f "$REPO_ROOT/.env" ] || die ".env not found at $REPO_ROOT/.env (copy .env.example)"
  set -a; . "$REPO_ROOT/.env"; set +a
  [ -n "${HCLOUD_TOKEN:-}" ] || die "HCLOUD_TOKEN is empty in .env"
  [ -n "${CLOUDFLARE_KUBETEST_API_TOKEN:-}" ] || die "CLOUDFLARE_KUBETEST_API_TOKEN is empty in .env"
}

# Always pin the token explicitly. The active hcloud *context* points at a
# different project, and we never switch it — so nothing can land in the
# wrong project even if a command is run by hand.
h() { HCLOUD_TOKEN="$HCLOUD_TOKEN" hcloud "$@"; }

cf() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-s -X "$method"
    -H "Authorization: Bearer $CLOUDFLARE_KUBETEST_API_TOKEN"
    -H "Content-Type: application/json")
  [ -n "$data" ] && args+=(--data "$data")
  curl "${args[@]}" "https://api.cloudflare.com/client/v4$path"
}

# Read a JSON field with python3 (always present; avoids a jq dependency)
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null || true; }

server_ip() { h server describe "$SERVER_NAME" -o format='{{.PublicNet.IPv4.IP}}' 2>/dev/null || true; }

my_ip() { curl -s -4 --max-time 10 ifconfig.me; }

# Run a command on the VM
onvm() { ssh -o StrictHostKeyChecking=accept-new "$SERVER_NAME" "$@"; }
