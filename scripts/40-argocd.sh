#!/usr/bin/env bash
# Install Argo CD, seed the one secret that can't live in git, and hand the
# cluster over to GitOps via the app-of-apps root Application.
#
# Everything after this point is managed BY Argo CD from this repo — that is
# the whole point. Only the bootstrap itself is imperative, because Argo CD
# cannot install itself.

. "$(dirname "$0")/lib.sh"
load_env

K="kubectl --context $KUBE_CONTEXT"

$K cluster-info >/dev/null 2>&1 || die "context '$KUBE_CONTEXT' can't reach the cluster — run 30-kubeconfig.sh"

# --- 1. Argo CD ---
log "Installing Argo CD"
$K create namespace argocd --dry-run=client -o yaml | $K apply -f -
# --server-side is REQUIRED: the applicationsets CRD is larger than the 256KB
# limit on the last-applied-configuration annotation that client-side apply
# writes, so a plain `kubectl apply` fails with "metadata.annotations: Too long".
$K apply --server-side --force-conflicts \
  -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# --- 2. Run argocd-server in insecure mode ---
# Argo CD terminates TLS itself by default; behind ingress-nginx that causes an
# infinite redirect loop. Serving plain HTTP internally and letting nginx do TLS
# is the documented fix. This pairs with backend-protocol "HTTP" on the Ingress
# (see manifests/config/argocd-ingress.yaml).
log "Configuring argocd-server for ingress (insecure mode)"
$K -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'

log "Waiting for Argo CD to become ready (this takes a minute or two)"
$K -n argocd rollout restart deployment argocd-server
$K -n argocd wait --for=condition=available --timeout=300s \
  deployment/argocd-server deployment/argocd-repo-server deployment/argocd-redis

# --- 3. The one secret that cannot be in git ---
# cert-manager's DNS-01 solver needs the Cloudflare token. This repo is public,
# so the secret is created imperatively from .env and never committed.
# (Next lesson, if you want it: sealed-secrets or SOPS so this too can be GitOps.)
log "Creating cert-manager Cloudflare API token secret"
$K create namespace cert-manager --dry-run=client -o yaml | $K apply -f -
$K -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_KUBETEST_API_TOKEN" \
  --dry-run=client -o yaml | $K apply -f -

# --- 4. Hand over to GitOps ---
log "Applying root Application (app-of-apps)"
$K apply -f "$REPO_ROOT/manifests/root-app.yaml"

# --- 5. Service account for Argo Workflows examples ---
# The workflows namespace is created by Argo CD; wait for it, then add the SA
# that the example workflows expect.
log "Waiting for the 'argo' namespace to be created by Argo CD"
for i in $(seq 1 60); do
  $K get namespace argo >/dev/null 2>&1 && break
  sleep 5
done
if $K get namespace argo >/dev/null 2>&1; then
  $K -n argo create serviceaccount argo-workflow --dry-run=client -o yaml | $K apply -f -
  $K create clusterrolebinding argo-workflow-admin \
    --clusterrole=admin --serviceaccount=argo:argo-workflow \
    --dry-run=client -o yaml | $K apply -f -
  log "ServiceAccount argo:argo-workflow ready"
else
  warn "namespace 'argo' not created yet — re-run this script once cert-manager and argo-workflows have synced"
fi

# --- 6. Credentials ---
PW=$($K -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

cat <<EOF

$(printf '\033[1;32m=== Argo playground ready ===\033[0m')

  Argo CD         https://$ARGOCD_HOST
  Argo Workflows  https://$ARGOWF_HOST

  username        admin
  password        ${PW:-<not available; kubectl -n argocd get secret argocd-initial-admin-secret>}

Certificates take a few minutes to issue (Let's Encrypt DNS-01). Watch with:
  kubectl --context $KUBE_CONTEXT get certificate -A -w

Watch the app-of-apps sync:
  kubectl --context $KUBE_CONTEXT get applications -n argocd -w

EOF
