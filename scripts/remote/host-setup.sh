#!/usr/bin/env bash
# Runs ON the VM as root. Installs docker/kubectl/helm/minikube, creates the
# 'argo' user that owns the cluster, and starts minikube.
# Expects PUBLIC_IP and APISERVER_PORT in the environment.

set -euo pipefail
log() { printf '\033[1;34m[vm]\033[0m %s\n' "$*"; }

: "${PUBLIC_IP:?PUBLIC_IP not set}"
: "${APISERVER_PORT:=6443}"

export DEBIAN_FRONTEND=noninteractive

log "Installing base packages"
apt-get update -qq
# Preseed iptables-persistent so it doesn't open an interactive dialog
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
apt-get install -y -qq curl ca-certificates conntrack iptables iptables-persistent jq apt-transport-https gnupg

# --- Docker ---
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  systemctl enable --now docker
else
  log "Docker already installed"
fi

# --- kubectl ---
if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl"
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
fi

# --- helm ---
if ! command -v helm >/dev/null 2>&1; then
  log "Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- minikube ---
if ! command -v minikube >/dev/null 2>&1; then
  log "Installing minikube"
  curl -fsSL https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 -o /usr/local/bin/minikube
  chmod +x /usr/local/bin/minikube
fi

# --- dedicated non-root user owns the cluster ---
# minikube's docker driver refuses to run as root without --force; a real user
# is the supported path and keeps the kubeconfig in a sane place.
if ! id argo >/dev/null 2>&1; then
  log "Creating 'argo' user"
  useradd -m -s /bin/bash argo
fi
usermod -aG docker argo
loginctl enable-linger argo 2>/dev/null || true

# --- start minikube ---
log "Starting minikube (this takes a few minutes on first run)"
sudo -u argo -H env \
  PUBLIC_IP="$PUBLIC_IP" APISERVER_PORT="$APISERVER_PORT" \
  bash -c '
    set -euo pipefail
    if minikube status --format "{{.Host}}" 2>/dev/null | grep -q Running; then
      echo "[vm] minikube already running"
    else
      minikube start \
        --driver=docker \
        --cpus=4 \
        --memory=6g \
        --apiserver-port="$APISERVER_PORT" \
        --listen-address=0.0.0.0 \
        --apiserver-ips="$PUBLIC_IP" \
        --apiserver-names=argo.kubetest.uk \
        --addons=ingress,storage-provisioner,default-storageclass
    fi
    minikube addons enable ingress    >/dev/null 2>&1 || true
    minikube addons enable metrics-server >/dev/null 2>&1 || true
  '

NODE_IP=$(sudo -u argo -H minikube ip)
log "minikube node IP: $NODE_IP"

# --- DNAT: host :80/:443/:6443 -> minikube ---
# The docker driver runs the cluster inside a container on an internal bridge,
# so neither ingress-nginx nor the API server is on the host's public interface.
#
# For the API server specifically: --apiserver-port sets the port INSIDE the
# container, and docker then publishes it on a *random* host port (32xxx) that
# changes on every `minikube start`. DNAT gives us a stable public :6443
# regardless of what docker picks, which is what the firewall rule and the
# laptop kubeconfig both depend on.
cat > /usr/local/bin/argo-dnat.sh <<'DNAT'
#!/usr/bin/env bash
set -euo pipefail
NODE_IP=$(sudo -u argo -H minikube ip 2>/dev/null) || exit 0
[ -n "$NODE_IP" ] || exit 0

# The public-facing interface. CRITICAL: the DNAT rules below MUST be scoped to
# it. PREROUTING sees every packet arriving at the host, including pod egress
# forwarded off the minikube bridge — so an unscoped "--dport 443 -j DNAT" also
# catches a pod dialing out to quay.io:443 and bounces it back into the cluster,
# breaking all outbound HTTPS (every image pull fails with i/o timeout).
PUB_IF=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
[ -n "$PUB_IF" ] || PUB_IF=eth0

PORTS="80 443 6443"

# Remove rules from a previous run so this converges instead of stacking.
# Includes the old unscoped form, so an upgrade cleans up after itself.
for p in $PORTS; do
  while iptables -t nat -D PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$NODE_IP:$p" 2>/dev/null; do :; done
  while iptables -t nat -D PREROUTING -i "$PUB_IF" -p tcp --dport "$p" -j DNAT --to-destination "$NODE_IP:$p" 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -d "$NODE_IP" -p tcp --dport "$p" -j MASQUERADE 2>/dev/null; do :; done
  while iptables -D DOCKER-USER -p tcp -d "$NODE_IP" --dport "$p" -j ACCEPT 2>/dev/null; do :; done
done

for p in $PORTS; do
  iptables -t nat -A PREROUTING -i "$PUB_IF" -p tcp --dport "$p" -j DNAT --to-destination "$NODE_IP:$p"
  iptables -t nat -A POSTROUTING -d "$NODE_IP" -p tcp --dport "$p" -j MASQUERADE
  # Docker's FORWARD chain drops unpublished container traffic by default.
  iptables -I DOCKER-USER -p tcp -d "$NODE_IP" --dport "$p" -j ACCEPT
done

echo "DNAT active on $PUB_IF: :80/:443/:6443 -> $NODE_IP"
DNAT
chmod +x /usr/local/bin/argo-dnat.sh
/usr/local/bin/argo-dnat.sh

# --- survive reboot ---
cat > /etc/systemd/system/argo-playground.service <<UNIT
[Unit]
Description=minikube Argo playground
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=argo
Group=argo
ExecStart=/usr/local/bin/minikube start --driver=docker --cpus=4 --memory=6g --apiserver-port=${APISERVER_PORT} --listen-address=0.0.0.0 --apiserver-ips=${PUBLIC_IP} --apiserver-names=argo.kubetest.uk
ExecStartPost=/usr/bin/sudo /usr/local/bin/argo-dnat.sh
ExecStop=/usr/local/bin/minikube stop
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT

# Let the argo user re-apply DNAT after minikube restarts
echo 'argo ALL=(root) NOPASSWD: /usr/local/bin/argo-dnat.sh' > /etc/sudoers.d/argo-dnat
chmod 440 /etc/sudoers.d/argo-dnat

systemctl daemon-reload
systemctl enable argo-playground.service >/dev/null 2>&1 || true

log "Cluster is up:"
sudo -u argo -H kubectl get nodes
log "Host setup complete."
