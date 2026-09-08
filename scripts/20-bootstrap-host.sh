#!/usr/bin/env bash
# Ship host-setup.sh to the VM and run it.

. "$(dirname "$0")/lib.sh"
load_env

IP="$(server_ip)"
[ -n "$IP" ] || die "server '$SERVER_NAME' not found — run 00-provision.sh first"

log "Copying host-setup.sh to $SERVER_NAME"
scp -o StrictHostKeyChecking=accept-new \
  "$REPO_ROOT/scripts/remote/host-setup.sh" "$SERVER_NAME:/root/host-setup.sh"

log "Running host setup (installs docker/kubectl/helm/minikube, starts cluster)"
onvm "chmod +x /root/host-setup.sh && PUBLIC_IP='$IP' APISERVER_PORT='$APISERVER_PORT' /root/host-setup.sh"

log "Host bootstrap complete. Next: scripts/30-kubeconfig.sh"
