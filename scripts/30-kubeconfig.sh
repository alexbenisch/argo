#!/usr/bin/env bash
# Pull minikube's client certs off the VM and merge an 'argo-playground'
# context into ~/.kube/config. Existing contexts are preserved (a timestamped
# backup is taken before any write).

. "$(dirname "$0")/lib.sh"
load_env

IP="$(server_ip)"
[ -n "$IP" ] || die "server '$SERVER_NAME' not found — run 00-provision.sh first"

CERT_DIR="$HOME/.kube/argo-playground"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

log "Fetching cluster CA and client certs from the VM"
onvm "cat /home/argo/.minikube/ca.crt"                          > "$CERT_DIR/ca.crt"
onvm "cat /home/argo/.minikube/profiles/minikube/client.crt"    > "$CERT_DIR/client.crt"
onvm "cat /home/argo/.minikube/profiles/minikube/client.key"    > "$CERT_DIR/client.key"
chmod 600 "$CERT_DIR"/*
for f in ca.crt client.crt client.key; do
  [ -s "$CERT_DIR/$f" ] || die "$f came back empty — is minikube running on the VM?"
done

# We always talk to the stable DNAT'd port on the host, never the random host
# port docker assigns to the minikube container (see argo-dnat.sh on the VM).
REMOTE_PORT="$APISERVER_PORT"
SERVER_URL="https://${IP}:${REMOTE_PORT}"
log "API server: $SERVER_URL"

STANDALONE="$CERT_DIR/config"
cat > "$STANDALONE" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: $KUBE_CONTEXT
  cluster:
    server: $SERVER_URL
    certificate-authority: $CERT_DIR/ca.crt
users:
- name: $KUBE_CONTEXT
  user:
    client-certificate: $CERT_DIR/client.crt
    client-key: $CERT_DIR/client.key
contexts:
- name: $KUBE_CONTEXT
  context:
    cluster: $KUBE_CONTEXT
    user: $KUBE_CONTEXT
current-context: $KUBE_CONTEXT
EOF
chmod 600 "$STANDALONE"

MAIN="$HOME/.kube/config"
if [ -f "$MAIN" ]; then
  BACKUP="$MAIN.bak.$(date +%Y%m%d%H%M%S)"
  cp "$MAIN" "$BACKUP"
  log "Backed up existing kubeconfig -> $BACKUP"

  # Drop a previous incarnation of this context so re-runs converge.
  kubectl config delete-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  kubectl config delete-user    "$KUBE_CONTEXT" >/dev/null 2>&1 || true

  MERGED="$(mktemp)"
  KUBECONFIG="$MAIN:$STANDALONE" kubectl config view --flatten > "$MERGED"
  mv "$MERGED" "$MAIN"
  chmod 600 "$MAIN"
else
  cp "$STANDALONE" "$MAIN"
  chmod 600 "$MAIN"
fi

# --flatten adopts the standalone file's current-context; put it back where it was.
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

log "Verifying from this machine..."
if kubectl --context "$KUBE_CONTEXT" get nodes 2>&1; then
  log "kubectl works. Context '$KUBE_CONTEXT' is active."
else
  die "could not reach the API server — check the firewall allows $(my_ip)/32 on $REMOTE_PORT"
fi

log "Next: scripts/40-argocd.sh"
