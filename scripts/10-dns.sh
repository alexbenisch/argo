#!/usr/bin/env bash
# Point argo.kubetest.uk and argo-wf.kubetest.uk at the VM. Idempotent.
# Records are deliberately NOT proxied: Let's Encrypt and the argocd CLI's
# gRPC both need to reach the origin directly.

. "$(dirname "$0")/lib.sh"
load_env

IP="$(server_ip)"
[ -n "$IP" ] || die "server '$SERVER_NAME' not found — run 00-provision.sh first"
log "Pointing DNS at $IP"

upsert_a() {
  local name="$1"
  local fqdn="$name.$CF_ZONE_NAME"
  local existing
  existing=$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=A&name=$fqdn" \
    | jget "(d['result'][0]['id'] if d.get('result') else '')")

  local payload
  payload=$(printf '{"type":"A","name":"%s","content":"%s","ttl":120,"proxied":false}' "$name" "$IP")

  local resp ok
  if [ -n "$existing" ]; then
    resp=$(cf PUT "/zones/$CF_ZONE_ID/dns_records/$existing" "$payload")
    ok=$(echo "$resp" | jget "d.get('success')")
    [ "$ok" = "True" ] || die "failed to update $fqdn: $(echo "$resp" | jget "d.get('errors')")"
    log "Updated  $fqdn -> $IP"
  else
    resp=$(cf POST "/zones/$CF_ZONE_ID/dns_records" "$payload")
    ok=$(echo "$resp" | jget "d.get('success')")
    [ "$ok" = "True" ] || die "failed to create $fqdn: $(echo "$resp" | jget "d.get('errors')")"
    log "Created  $fqdn -> $IP"
  fi
}

upsert_a argo
upsert_a argo-wf

log "Verifying resolution via Cloudflare DNS..."
for fqdn in "$ARGOCD_HOST" "$ARGOWF_HOST"; do
  got=$(dig +short @1.1.1.1 "$fqdn" A | head -1)
  if [ "$got" = "$IP" ]; then
    log "  $fqdn resolves to $got"
  else
    warn "  $fqdn resolves to '${got:-nothing}' (expected $IP) — may just be TTL lag"
  fi
done

log "DNS done. Next: scripts/20-bootstrap-host.sh"
