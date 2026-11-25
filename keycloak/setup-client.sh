#!/bin/bash
# Richtet den Keycloak-Client für das Fahrzeugbuch ein – nur client-bezogen, idempotent.
#
# Direkt (kcadm.sh installiert):
#   KC_URL=https://id.j-mb.net REALM=<realm> KC_ADMIN=admin ./setup-client.sh
# Im Keycloak-Container:
#   docker exec -i -e KC_URL=http://localhost:8080 -e REALM=<realm> -e KC_ADMIN=admin \
#     -e KC_ADMIN_PASSWORD=... <keycloak-container> bash -s < setup-client.sh
#
# Optional: KC_ADMIN_REALM (master), CLIENT (fahrzeugbuch-ios),
#           REDIRECT (net.jmb.fahrzeugbuch:/oauth2redirect), ROLE (fahrzeugbuch-user),
#           ASSIGN_USERS ("jakob anna" → erhalten die Rolle), KCADM
set -euo pipefail

: "${KC_URL:?KC_URL setzen (z. B. https://id.j-mb.net)}"
: "${REALM:?REALM setzen}"
: "${KC_ADMIN:?KC_ADMIN setzen}"
KC_ADMIN_REALM=${KC_ADMIN_REALM:-master}
CLIENT=${CLIENT:-fahrzeugbuch-ios}
REDIRECT=${REDIRECT:-net.jmb.fahrzeugbuch:/oauth2redirect}
ROLE=${ROLE:-fahrzeugbuch-user}
ASSIGN_USERS=${ASSIGN_USERS:-}
if [[ -z "${KCADM:-}" ]]; then
  KCADM=$(command -v kcadm.sh || echo /opt/keycloak/bin/kcadm.sh)
fi
CFG=/tmp/kcadm-fahrzeugbuch.config

kc() { "$KCADM" "$@" --config "$CFG"; }
warn() { echo "WARNUNG: $*" >&2; }

if [[ -n "${KC_ADMIN_PASSWORD:-}" ]]; then export KC_CLI_PASSWORD=$KC_ADMIN_PASSWORD; fi
kc config credentials --server "$KC_URL" --realm "$KC_ADMIN_REALM" --user "$KC_ADMIN"
kc get "realms/$REALM" --fields realm >/dev/null || { echo "Realm $REALM nicht gefunden" >&2; exit 1; }

# --- Client (public, Authorization Code + PKCE S256) -------------------------
ATTRS=(
  -s clientId="$CLIENT"
  -s name="Fahrzeugbuch iOS"
  -s protocol=openid-connect
  -s publicClient=true
  -s standardFlowEnabled=true
  -s directAccessGrantsEnabled=false
  -s implicitFlowEnabled=false
  -s serviceAccountsEnabled=false
  -s frontchannelLogout=false
  -s "redirectUris=[\"$REDIRECT\"]"
  -s 'webOrigins=[]'
  -s 'attributes."pkce.code.challenge.method"=S256'
  -s "attributes.\"post.logout.redirect.uris\"=$REDIRECT"
)
client_id() { kc get clients -r "$REALM" -q clientId="$CLIENT" --fields id --format csv --noquotes | head -1; }
ID=$(client_id)
if [[ -z "$ID" ]]; then
  kc create clients -r "$REALM" "${ATTRS[@]}" >/dev/null
  ID=$(client_id)
  echo "Client $CLIENT angelegt"
else
  kc update "clients/$ID" -r "$REALM" "${ATTRS[@]}"
  echo "Client $CLIENT aktualisiert"
fi

# --- offline_access (Refresh-Token übersteht SSO-Session-Timeout) ------------
# Reines Bash (Keycloak-Image hat weder awk noch jq)
SCOPE_ID=""
while IFS=, read -r sid sname; do
  [[ "$sname" == "offline_access" ]] && SCOPE_ID=$sid
done < <(kc get client-scopes -r "$REALM" --fields id,name --format csv --noquotes)
if [[ -n "$SCOPE_ID" ]]; then
  kc update "clients/$ID/optional-client-scopes/$SCOPE_ID" -r "$REALM"
else
  warn "Client-Scope offline_access fehlt im Realm – App muss sich nach SSO-Timeout neu anmelden"
fi

# --- Client-Rolle -------------------------------------------------------------
if ! kc get "clients/$ID/roles/$ROLE" -r "$REALM" >/dev/null 2>&1; then
  kc create "clients/$ID/roles" -r "$REALM" -s name="$ROLE" -s description="Zugriff auf das Fahrzeugbuch"
  echo "Rolle $ROLE angelegt"
fi
for u in $ASSIGN_USERS; do
  kc add-roles -r "$REALM" --uusername "$u" --cclientid "$CLIENT" --rolename "$ROLE" && echo "Rolle → $u"
done

ISSUER="${KC_PUBLIC_URL:-$KC_URL}/realms/$REALM"
cat <<INFO

Fertig. Portainer-Stack-Variablen:
  OIDC_ISSUER=$ISSUER
  OIDC_CLIENT_ID=$CLIENT
  OIDC_REQUIRED_ROLE=$ROLE
INFO
