#!/usr/bin/env bash
# Seed the in-cluster dev Vault and create the token Secret that the
# ClusterSecretStore authenticates with.
#
# Why this is imperative rather than GitOps: the KV data *is* the secret
# material, and this repo is public. Same reasoning as the Cloudflare token in
# 40-argocd.sh. (Next lesson, if you want it: Vault Kubernetes auth so the token
# Secret disappears too, and sealed-secrets/SOPS for the rest.)
#
# Vault runs in dev mode -> in-memory storage. Re-run this script after any
# vault-0 restart, or the ExternalSecrets go NotReady.
#
# Re-running also ROTATES both API keys, which is the interesting exercise:
# watch the dev/prod-api-credentials Secrets update within refreshInterval (1m)
# without anything being pushed to git.
#
# Usage:
#   scripts/60-vault-seed.sh                      # random keys
#   DEV_API_KEY=... PROD_API_KEY=... scripts/60-vault-seed.sh

. "$(dirname "$0")/lib.sh"

K="kubectl --context $KUBE_CONTEXT"

$K cluster-info >/dev/null 2>&1 || die "context '$KUBE_CONTEXT' can't reach the cluster — run 30-kubeconfig.sh"

VAULT_NS="vault"
VAULT_POD="vault-0"
# Dev-mode Vault's fixed root token, set by manifests/apps/vault.yaml. Not a
# real credential — it is a documented constant of `vault server -dev`.
ROOT_TOKEN="root"

DEV_API_KEY="${DEV_API_KEY:-dev-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
PROD_API_KEY="${PROD_API_KEY:-prod-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

# --- 1. Wait for Vault ---
log "Waiting for $VAULT_NS/$VAULT_POD (Argo CD has to sync the vault app first)"
for i in $(seq 1 60); do
  $K -n "$VAULT_NS" get pod "$VAULT_POD" >/dev/null 2>&1 && break
  sleep 5
done
$K -n "$VAULT_NS" get pod "$VAULT_POD" >/dev/null 2>&1 \
  || die "$VAULT_NS/$VAULT_POD never appeared — check 'kubectl get application vault -n argocd'"
$K -n "$VAULT_NS" wait --for=condition=ready --timeout=180s "pod/$VAULT_POD"

# Run a vault CLI command inside the pod. Dev mode listens on plain HTTP.
v() {
  $K -n "$VAULT_NS" exec "$VAULT_POD" -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$ROOT_TOKEN" vault "$@"
}

# --- 2. KV v2 mount at org/kv ---
# Dev mode pre-mounts kv-v2 at secret/, but the tutorial (and the store in
# examples/vault-external-secrets/secret-store.yaml) uses org/kv.
if v secrets list -format=json | grep -q '"org/kv/"'; then
  log "KV v2 mount org/kv already exists"
else
  log "Enabling KV v2 mount at org/kv"
  v secrets enable -path=org/kv kv-v2
fi

# --- 3. The secret material ---
log "Writing org/kv/dev and org/kv/prod"
v kv put org/kv/dev  api-key="$DEV_API_KEY"  >/dev/null
v kv put org/kv/prod api-key="$PROD_API_KEY" >/dev/null

# --- 4. The Vault token the ClusterSecretStore authenticates with ---
log "Creating Secret $VAULT_NS/vault-token"
$K -n "$VAULT_NS" create secret generic vault-token \
  --from-literal=token="$ROOT_TOKEN" \
  --dry-run=client -o yaml | $K apply -f -

cat <<EOF

$(printf '\033[1;32m=== Vault seeded ===\033[0m')

  org/kv/dev   api-key = $DEV_API_KEY
  org/kv/prod  api-key = $PROD_API_KEY

External Secrets refreshes every 60s. Watch it land:

  $K get externalsecret -A -w
  $K -n dev  get secret dev-api-credentials  -o jsonpath='{.data.api-key}' | base64 -d; echo
  $K -n prod get secret prod-api-credentials -o jsonpath='{.data.api-key}' | base64 -d; echo

The api-consumer pods read the key as an env var at start, so they keep the old
value until restarted:

  $K -n dev rollout restart deployment/api-consumer
  $K -n dev logs -l app=api-consumer --tail=1

EOF
