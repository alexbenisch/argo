#!/usr/bin/env bash
# Provision the Hetzner VM: ssh key, firewall, server, ~/.ssh/config entry.
# Idempotent — safe to re-run.

. "$(dirname "$0")/lib.sh"
load_env

MY_IP="$(my_ip)"
[ -n "$MY_IP" ] || die "could not determine your public IP"
log "Your public IP: $MY_IP"

# --- 1. SSH key (per ~/.claude/commands/ssh.md: one dedicated key per server) ---
if [ -f "$SSH_KEY_PATH" ]; then
  log "SSH key $SSH_KEY_PATH already exists, reusing"
else
  log "Generating SSH key $SSH_KEY_PATH"
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -C "$SSH_KEY_NAME" -N ""
fi

if h ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
  log "hcloud ssh-key '$SSH_KEY_NAME' already uploaded"
else
  log "Uploading public key to the argo-playground Hetzner project"
  h ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "${SSH_KEY_PATH}.pub"
fi

# --- 2. Firewall ---
if h firewall describe "$FIREWALL_NAME" >/dev/null 2>&1; then
  log "Firewall '$FIREWALL_NAME' exists — resetting rules to match current IP"
else
  log "Creating firewall '$FIREWALL_NAME'"
  h firewall create --name "$FIREWALL_NAME"
fi

# Replace the whole ruleset in one shot so re-runs converge instead of stacking rules.
RULES_JSON=$(cat <<EOF
[
  {"direction":"in","protocol":"tcp","port":"22","source_ips":["$MY_IP/32"],"description":"SSH from alex"},
  {"direction":"in","protocol":"tcp","port":"$APISERVER_PORT","source_ips":["$MY_IP/32"],"description":"k8s API from alex"},
  {"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"],"description":"HTTP ingress"},
  {"direction":"in","protocol":"tcp","port":"443","source_ips":["0.0.0.0/0","::/0"],"description":"HTTPS ingress"},
  {"direction":"in","protocol":"icmp","source_ips":["0.0.0.0/0","::/0"],"description":"ping"}
]
EOF
)
TMP_RULES="$(mktemp)"; echo "$RULES_JSON" > "$TMP_RULES"
h firewall replace-rules "$FIREWALL_NAME" --rules-file "$TMP_RULES"
rm -f "$TMP_RULES"
log "Firewall rules applied (SSH + API locked to $MY_IP/32)"

# --- 3. Server ---
if h server describe "$SERVER_NAME" >/dev/null 2>&1; then
  log "Server '$SERVER_NAME' already exists"
else
  log "Creating server '$SERVER_NAME' ($SERVER_TYPE, $SERVER_IMAGE, $SERVER_LOCATION)"
  h server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --image "$SERVER_IMAGE" \
    --location "$SERVER_LOCATION" \
    --ssh-key "$SSH_KEY_NAME" \
    --firewall "$FIREWALL_NAME"
fi

IP="$(server_ip)"
[ -n "$IP" ] || die "could not read server IP"
log "Server IP: $IP"

# --- 4. ~/.ssh/config entry ---
SSH_CONFIG="$HOME/.ssh/config"
if grep -qE "^Host $SERVER_NAME\$" "$SSH_CONFIG" 2>/dev/null; then
  log "Updating HostName in existing '$SERVER_NAME' ssh config block"
  # Rewrite only the HostName line inside this Host block
  python3 - "$SSH_CONFIG" "$SERVER_NAME" "$IP" <<'PY'
import sys, re
path, host, ip = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split('\n')
out, inblock = [], False
for line in lines:
    if re.match(rf'^Host {re.escape(host)}$', line):
        inblock = True
    elif re.match(r'^Host ', line):
        inblock = False
    if inblock and re.match(r'^\s+HostName ', line):
        line = re.sub(r'(^\s+HostName ).*', rf'\g<1>{ip}', line)
    out.append(line)
open(path, 'w').write('\n'.join(out))
PY
else
  log "Appending '$SERVER_NAME' to $SSH_CONFIG"
  cat >> "$SSH_CONFIG" <<EOF

Host $SERVER_NAME
  HostName $IP
  User root
  IdentityFile $SSH_KEY_PATH
  IdentitiesOnly yes
  ForwardAgent yes
EOF
fi

# Drop any stale host key from a previous incarnation of this IP
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

# --- 5. Wait for SSH ---
log "Waiting for SSH to come up..."
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$SERVER_NAME" true 2>/dev/null; then
    log "SSH is up"
    break
  fi
  [ "$i" = 60 ] && die "SSH did not come up within ~5 minutes"
  sleep 5
done

log "Provisioned. Next: scripts/10-dns.sh"
