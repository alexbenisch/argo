#!/usr/bin/env bash
# Tear down everything the 00/10/20/30 scripts created: the Hetzner server,
# firewall and ssh-key, the Cloudflare DNS records, and all local state
# (ssh config block, ssh keys, kubeconfig entries). Safe to re-run — every
# step tolerates the resource already being absent.
#
# Usage:
#   scripts/99-teardown.sh            # prompts for confirmation
#   scripts/99-teardown.sh --force    # skips the prompt

set -euo pipefail

. "$(dirname "$0")/lib.sh"
load_env

if [ "${1:-}" != "--force" ]; then
  read -r -p "This will permanently destroy the argo-playground server, firewall, DNS records, and local kube/ssh config. Type 'yes' to continue: " CONFIRM || true
  [ "${CONFIRM:-}" = "yes" ] || die "Aborted (typed '${CONFIRM:-}', not 'yes')."
fi

REMOVED=()

# --- 1. Hetzner server ---
log "Deleting Hetzner server '$SERVER_NAME'"
if h server delete "$SERVER_NAME" >/dev/null 2>&1; then
  REMOVED+=("Hetzner server: $SERVER_NAME")
else
  warn "Server '$SERVER_NAME' not found (already deleted?)"
fi

# --- 2. Firewall ---
log "Deleting Hetzner firewall '$FIREWALL_NAME'"
if h firewall delete "$FIREWALL_NAME" >/dev/null 2>&1; then
  REMOVED+=("Hetzner firewall: $FIREWALL_NAME")
else
  warn "Firewall '$FIREWALL_NAME' not found (already deleted?)"
fi

# --- 3. hcloud ssh-key ---
log "Deleting hcloud ssh-key '$SSH_KEY_NAME'"
if h ssh-key delete "$SSH_KEY_NAME" >/dev/null 2>&1; then
  REMOVED+=("hcloud ssh-key: $SSH_KEY_NAME")
else
  warn "hcloud ssh-key '$SSH_KEY_NAME' not found (already deleted?)"
fi

# --- 4. Cloudflare DNS records ---
delete_a() {
  local name="$1" fqdn id
  fqdn="$name.$CF_ZONE_NAME"
  id=$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=A&name=$fqdn" \
    | jget "(d['result'][0]['id'] if d.get('result') else '')")
  if [ -n "$id" ]; then
    cf DELETE "/zones/$CF_ZONE_ID/dns_records/$id" >/dev/null
    REMOVED+=("Cloudflare A record: $fqdn")
    log "Deleted DNS record $fqdn"
  else
    warn "DNS record $fqdn not found (already deleted?)"
  fi
}
delete_a argo
delete_a argo-wf

# --- 5. ~/.ssh/config 'Host argo-playground' block ---
SSH_CONFIG="$HOME/.ssh/config"
if [ -f "$SSH_CONFIG" ] && grep -qE "^Host $SERVER_NAME\$" "$SSH_CONFIG"; then
  log "Removing 'Host $SERVER_NAME' block from $SSH_CONFIG"
  python3 - "$SSH_CONFIG" "$SERVER_NAME" <<'PY'
import sys, re
path, host = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
out, skipping = [], False
for line in lines:
    if re.match(rf'^Host {re.escape(host)}$', line):
        skipping = True
        continue
    if skipping:
        # Continuation lines of the block are indented (or blank); the first
        # non-indented, non-blank line ends the block.
        if line.strip() == '' or line.startswith((' ', '\t')):
            continue
        skipping = False
    out.append(line)
open(path, 'w').write('\n'.join(out))
PY
  REMOVED+=("~/.ssh/config block: Host $SERVER_NAME")
else
  warn "No 'Host $SERVER_NAME' block found in $SSH_CONFIG"
fi

# --- 6. Local SSH key pair ---
if [ -f "$SSH_KEY_PATH" ] || [ -f "${SSH_KEY_PATH}.pub" ]; then
  rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
  REMOVED+=("local SSH key pair: $SSH_KEY_PATH{,.pub}")
  log "Removed local SSH key pair"
else
  warn "Local SSH key pair $SSH_KEY_PATH{,.pub} not found"
fi

# --- 7. Local kubeconfig cert dir ---
CERT_DIR="$HOME/.kube/argo-playground"
if [ -d "$CERT_DIR" ]; then
  rm -rf "$CERT_DIR"
  REMOVED+=("local kube cert dir: $CERT_DIR")
  log "Removed $CERT_DIR"
else
  warn "$CERT_DIR not found"
fi

# --- 8. kubectl context/cluster/user ---
log "Removing kubectl context/cluster/user '$KUBE_CONTEXT'"
kubectl config delete-context "$KUBE_CONTEXT" >/dev/null 2>&1 \
  && REMOVED+=("kubectl context: $KUBE_CONTEXT") \
  || warn "kubectl context '$KUBE_CONTEXT' not found"
kubectl config delete-cluster "$KUBE_CONTEXT" >/dev/null 2>&1 \
  && REMOVED+=("kubectl cluster: $KUBE_CONTEXT") \
  || warn "kubectl cluster '$KUBE_CONTEXT' not found"
kubectl config delete-user "$KUBE_CONTEXT" >/dev/null 2>&1 \
  && REMOVED+=("kubectl user: $KUBE_CONTEXT") \
  || warn "kubectl user '$KUBE_CONTEXT' not found"

# --- Summary ---
log "Teardown complete. Removed:"
if [ "${#REMOVED[@]}" -eq 0 ]; then
  echo "  (nothing — everything was already absent)"
else
  for item in "${REMOVED[@]}"; do
    echo "  - $item"
  done
fi
