#!/usr/bin/env bash
# Re-point the argo-playground firewall's SSH (22) and k8s API rules at the
# caller's CURRENT public IP. Run this whenever your home/office IP changes
# and you can no longer reach the box. 80/443 stay world-open (ingress).
#
# Replaces the whole ruleset in one shot (like scripts/00-provision.sh) so
# re-runs converge instead of stacking rules.

set -euo pipefail

. "$(dirname "$0")/lib.sh"
load_env

# Best-effort lookup of the currently-allowed SSH source IP, purely for the
# "old vs new" printout below. hcloud's JSON describe output isn't exercised
# elsewhere in this repo, so if the field layout doesn't match, we just fall
# back to printing "unknown" rather than failing the whole script.
OLD_IP=$(h firewall describe "$FIREWALL_NAME" -o json 2>/dev/null \
  | jget "next((r['source_ips'][0].split('/')[0] for r in d.get('rules', []) if r.get('port') == '22'), '')")
OLD_IP="${OLD_IP:-unknown}"

NEW_IP="$(my_ip)"
[ -n "$NEW_IP" ] || die "could not determine your current public IP"

log "Old allowed IP: $OLD_IP"
log "New allowed IP: $NEW_IP"

if [ "$OLD_IP" = "$NEW_IP" ]; then
  log "IP unchanged — re-applying rules anyway (idempotent)"
fi

RULES_JSON=$(cat <<EOF
[
  {"direction":"in","protocol":"tcp","port":"22","source_ips":["$NEW_IP/32"],"description":"SSH from alex"},
  {"direction":"in","protocol":"tcp","port":"$APISERVER_PORT","source_ips":["$NEW_IP/32"],"description":"k8s API from alex"},
  {"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"],"description":"HTTP ingress"},
  {"direction":"in","protocol":"tcp","port":"443","source_ips":["0.0.0.0/0","::/0"],"description":"HTTPS ingress"},
  {"direction":"in","protocol":"icmp","source_ips":["0.0.0.0/0","::/0"],"description":"ping"}
]
EOF
)
TMP_RULES="$(mktemp)"; echo "$RULES_JSON" > "$TMP_RULES"
h firewall replace-rules "$FIREWALL_NAME" --rules-file "$TMP_RULES"
rm -f "$TMP_RULES"

log "Firewall '$FIREWALL_NAME' updated: SSH + API now locked to $NEW_IP/32 (was $OLD_IP)"
