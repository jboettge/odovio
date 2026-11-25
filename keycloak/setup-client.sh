#!/bin/bash
# Richtet die Keycloak-Clients für das Fahrzeugbuch ein (iOS-App, Web-Frontend, optional Admin-API) –
# nur client-/gruppenbezogen, idempotent. Reines Bash (das Keycloak-Image hat weder awk noch jq).
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
# Web-Frontend (öffentlicher Client, PKCE S256, KEIN offline_access; nur dort: Mitgliederverwaltung und
# Steuerparameter – der Server prüft azp = OIDC_WEB_CLIENT_ID):
#           WEB_URL ("https://fahrzeugbuch.j-mb.net"; leer → Web-Client wird nicht angelegt/geändert),
#           WEB_CLIENT (fahrzeugbuch-web)
# Mandanten (Gruppen /fahrzeugbuch/<mandant> = schreiben, …/<mandant>/lesen = lesen,
#           …/<mandant>/admin = verwalten inkl. schreiben):
#           TENANTS ("privat b-re.ch")       → Gruppen anlegen (Mandant + lesen + admin)
#           MEMBERS ("privat=jakob,anna b-re.ch=jakob") → Schreibzugriff
#           READERS ("b-re.ch=treuhand")      → Lesezugriff
#           ADMINS  ("privat=jakob")          → Verwalter
#           Ein Benutzer sollte je Mandant in genau EINER der drei Gruppen sein (die App verwaltet das so);
#           das Skript entfernt keine Zuordnungen.
# Mitgliederverwaltung über die Admin-REST-API (optional):
#           CREATE_ADMIN_API=1 → vertraulicher Client ADMIN_API_CLIENT (fahrzeugbuch-admin-api) mit Service-
#           Account und den realm-management-Rollen view-users, query-users, query-groups, manage-users;
#           das Secret wird am Ende ausgegeben (→ KC_ADMIN_CLIENT_ID/KC_ADMIN_CLIENT_SECRET der API).
#           Hinweis: manage-users erlaubt dem Service-Account, ALLE Benutzer/Gruppen des Realms zu ändern.
# REALMWEITE Härtung – wirkt auf ALLE Clients und Benutzer des Realms, daher nur mit explizitem Flag:
#           ENABLE_BRUTE_FORCE=1   → bruteForceProtected (5 Fehlversuche, Wartezeit +60 s bis max. 15 min,
#                                    keine permanente Sperre)
#           SET_PASSWORD_POLICY=1  → passwordPolicy = PASSWORD_POLICY
#                                    (Default "length(12) and notUsername and passwordHistory(3)")
#           REQUIRE_ADMIN_OTP=1    → Required Action CONFIGURE_TOTP (realmweit aktivieren) und für alle
#                                    ADMINS-Benutzer ohne OTP setzen; danach verlangt der Standard-Browser-
#                                    Flow (Conditional OTP) bei jeder Anmeldung das OTP. Strenger: eigener Flow
#                                    mit „Condition – User Role/Group“ für die Gruppen …/admin.
#           Restriktiver: Keycloak 26 Fine-Grained Admin Permissions (FGAP v2, Realm-Einstellung „Admin
#           Permissions“) – statt manage-users nur Berechtigungen „manage-membership“/„view-members“ auf die
#           Gruppe /fahrzeugbuch (inkl. Untergruppen) und „view“ auf Benutzer für den Service-Account vergeben.
set -euo pipefail

: "${KC_URL:?KC_URL setzen (z. B. https://id.j-mb.net)}"
: "${REALM:?REALM setzen}"
: "${KC_ADMIN:?KC_ADMIN setzen}"
KC_ADMIN_REALM=${KC_ADMIN_REALM:-master}
CLIENT=${CLIENT:-fahrzeugbuch-ios}
REDIRECT=${REDIRECT:-net.jmb.fahrzeugbuch:/oauth2redirect}
ROLE=${ROLE:-fahrzeugbuch-user}
ASSIGN_USERS=${ASSIGN_USERS:-}
TENANTS=${TENANTS:-}
MEMBERS=${MEMBERS:-}
READERS=${READERS:-}
ADMINS=${ADMINS:-}
WEB_URL=${WEB_URL:-}
WEB_URL=${WEB_URL%/}
WEB_CLIENT=${WEB_CLIENT:-fahrzeugbuch-web}
CREATE_ADMIN_API=${CREATE_ADMIN_API:-0}
ENABLE_BRUTE_FORCE=${ENABLE_BRUTE_FORCE:-0}
SET_PASSWORD_POLICY=${SET_PASSWORD_POLICY:-0}
PASSWORD_POLICY=${PASSWORD_POLICY:-length(12) and notUsername and passwordHistory(3)}
REQUIRE_ADMIN_OTP=${REQUIRE_ADMIN_OTP:-0}
ADMIN_API_CLIENT=${ADMIN_API_CLIENT:-fahrzeugbuch-admin-api}
GROUP_ROOT=fahrzeugbuch
if [[ -z "${KCADM:-}" ]]; then
  KCADM=$(command -v kcadm.sh || echo /opt/keycloak/bin/kcadm.sh)
fi
CFG=/tmp/kcadm-fahrzeugbuch.config

kc() { "$KCADM" "$@" --config "$CFG"; }
warn() { echo "WARNUNG: $*" >&2; }

if [[ -n "${KC_ADMIN_PASSWORD:-}" ]]; then export KC_CLI_PASSWORD=$KC_ADMIN_PASSWORD; fi
kc config credentials --server "$KC_URL" --realm "$KC_ADMIN_REALM" --user "$KC_ADMIN"
kc get "realms/$REALM" --fields realm >/dev/null || { echo "Realm $REALM nicht gefunden" >&2; exit 1; }

# --- Hilfsfunktionen ------------------------------------------------------------
client_uuid() { kc get clients -r "$REALM" -q clientId="$1" --fields id --format csv --noquotes | head -1; }
upsert_client() {  # $1 = clientId, Rest = kcadm-Attribute; setzt CID
  local name=$1; shift
  CID=$(client_uuid "$name")
  if [[ -z "$CID" ]]; then
    kc create clients -r "$REALM" "$@" >/dev/null
    CID=$(client_uuid "$name")
    echo "Client $name angelegt"
  else
    kc update "clients/$CID" -r "$REALM" "$@"
    echo "Client $name aktualisiert"
  fi
}
scope_id() {  # $1 = Name des Client-Scopes
  local sid sname
  while IFS=, read -r sid sname; do
    [[ "$sname" == "$1" ]] && { echo "$sid"; return; }
  done < <(kc get client-scopes -r "$REALM" --fields id,name --format csv --noquotes)
  return 0
}
ensure_groups_mapper() {  # $1 = Client-UUID: Gruppen-Claim mit vollen Pfaden → Mandanten
  local mname
  while IFS=, read -r mname; do [[ "$mname" == "groups" ]] && return; done \
    < <(kc get "clients/$1/protocol-mappers/models" -r "$REALM" --fields name --format csv --noquotes)
  kc create "clients/$1/protocol-mappers/models" -r "$REALM" \
    -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."full.path"=true' -s 'config."claim.name"=groups' \
    -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' \
    -s 'config."userinfo.token.claim"=false' >/dev/null
  echo "Mapper groups angelegt"
}

# --- iOS-Client (public, Authorization Code + PKCE S256) ----------------------
upsert_client "$CLIENT" \
  -s clientId="$CLIENT" \
  -s name="Fahrzeugbuch iOS" \
  -s protocol=openid-connect \
  -s publicClient=true \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s implicitFlowEnabled=false \
  -s serviceAccountsEnabled=false \
  -s frontchannelLogout=false \
  -s "redirectUris=[\"$REDIRECT\"]" \
  -s 'webOrigins=[]' \
  -s 'attributes."pkce.code.challenge.method"=S256' \
  -s "attributes.\"post.logout.redirect.uris\"=$REDIRECT"
ID=$CID

# --- offline_access (Refresh-Token übersteht SSO-Session-Timeout) – nur iOS ----
SCOPE_ID=$(scope_id offline_access)
if [[ -n "$SCOPE_ID" ]]; then
  kc update "clients/$ID/optional-client-scopes/$SCOPE_ID" -r "$REALM"
else
  warn "Client-Scope offline_access fehlt im Realm – App muss sich nach SSO-Timeout neu anmelden"
fi

# --- Client-Rolle -------------------------------------------------------------
# (Web-Tokens enthalten sie ebenfalls: fullScopeAllowed ist Standard → resource_access.<ios-client>.roles)
if ! kc get "clients/$ID/roles/$ROLE" -r "$REALM" >/dev/null 2>&1; then
  kc create "clients/$ID/roles" -r "$REALM" -s name="$ROLE" -s description="Zugriff auf das Fahrzeugbuch"
  echo "Rolle $ROLE angelegt"
fi
for u in $ASSIGN_USERS; do
  kc add-roles -r "$REALM" --uusername "$u" --cclientid "$CLIENT" --rolename "$ROLE" && echo "Rolle → $u"
done
ensure_groups_mapper "$ID"

# --- Web-Frontend (public, PKCE S256, ohne offline_access) --------------------
if [[ -n "$WEB_URL" ]]; then
  upsert_client "$WEB_CLIENT" \
    -s clientId="$WEB_CLIENT" \
    -s name="Fahrzeugbuch Web" \
    -s protocol=openid-connect \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s implicitFlowEnabled=false \
    -s serviceAccountsEnabled=false \
    -s frontchannelLogout=false \
    -s "rootUrl=$WEB_URL" \
    -s "redirectUris=[\"$WEB_URL/auth/callback\"]" \
    -s "webOrigins=[\"$WEB_URL\"]" \
    -s 'attributes."pkce.code.challenge.method"=S256' \
    -s "attributes.\"post.logout.redirect.uris\"=$WEB_URL/"
  WEB_ID=$CID
  if [[ -n "$SCOPE_ID" ]]; then   # Browser: keine langlebigen Offline-Tokens
    kc delete "clients/$WEB_ID/optional-client-scopes/$SCOPE_ID" -r "$REALM" >/dev/null 2>&1 || true
    kc delete "clients/$WEB_ID/default-client-scopes/$SCOPE_ID" -r "$REALM" >/dev/null 2>&1 || true
  fi
  ensure_groups_mapper "$WEB_ID"
else
  warn "WEB_URL leer – Web-Client $WEB_CLIENT nicht angelegt (Verwaltung/Steuerparameter nur im Web-Frontend)"
fi

# --- Admin-API für die Mitgliederverwaltung (optional) ------------------------
ADMIN_API_SECRET=""
if [[ "$CREATE_ADMIN_API" == "1" ]]; then
  upsert_client "$ADMIN_API_CLIENT" \
    -s clientId="$ADMIN_API_CLIENT" \
    -s name="Fahrzeugbuch Admin-API (Service-Account)" \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s implicitFlowEnabled=false \
    -s serviceAccountsEnabled=true
  API_ID=$CID
  SA_USER=$(kc get "clients/$API_ID/service-account-user" -r "$REALM" --fields username --format csv --noquotes \
    | head -1)
  # minimale realm-management-Rollen (siehe Kopf: FGAP v2 als restriktivere Alternative)
  kc add-roles -r "$REALM" --uusername "$SA_USER" --cclientid realm-management \
    --rolename view-users --rolename query-users --rolename query-groups --rolename manage-users
  echo "Service-Account $SA_USER: view-users, query-users, query-groups, manage-users"
  ADMIN_API_SECRET=$(kc get "clients/$API_ID/client-secret" -r "$REALM" --fields value --format csv --noquotes \
    | head -1)
fi

group_id() { kc get "group-by-path/$1" -r "$REALM" --fields id --format csv --noquotes 2>/dev/null | head -1 || true; }
ensure_group() {  # $1 = Pfad ohne führenden Slash
  local path=$1 parent name gid pid
  gid=$(group_id "$path")
  [[ -n "$gid" ]] && { echo "$gid"; return; }
  name=${path##*/}
  if [[ "$path" == */* ]]; then
    parent=${path%/*}
    pid=$(ensure_group "$parent")
    kc create "groups/$pid/children" -r "$REALM" -s name="$name" >/dev/null
  else
    kc create groups -r "$REALM" -s name="$name" >/dev/null
  fi
  echo "Gruppe /$path angelegt" >&2
  group_id "$path"
}
user_id() { kc get users -r "$REALM" -q username="$1" -q exact=true --fields id --format csv --noquotes | head -1 || true; }
join() {  # $1 = Gruppenpfad, $2 = Benutzer
  local gid uid
  gid=$(ensure_group "$1")
  uid=$(user_id "$2")
  [[ -z "$uid" ]] && { warn "Benutzer $2 nicht gefunden"; return; }
  kc update "users/$uid/groups/$gid" -r "$REALM" -s realm="$REALM" -s userId="$uid" -s groupId="$gid" -n
  echo "$2 → /$1"
}

for t in $TENANTS; do
  ensure_group "$GROUP_ROOT/$t" >/dev/null
  ensure_group "$GROUP_ROOT/$t/lesen" >/dev/null
  ensure_group "$GROUP_ROOT/$t/admin" >/dev/null
done
for pair in $MEMBERS; do
  t=${pair%%=*}
  IFS=, read -ra users <<< "${pair#*=}"
  for u in "${users[@]}"; do join "$GROUP_ROOT/$t" "$u"; done
done
for pair in $READERS; do
  t=${pair%%=*}
  IFS=, read -ra users <<< "${pair#*=}"
  for u in "${users[@]}"; do join "$GROUP_ROOT/$t/lesen" "$u"; done
done
for pair in $ADMINS; do
  t=${pair%%=*}
  IFS=, read -ra users <<< "${pair#*=}"
  for u in "${users[@]}"; do join "$GROUP_ROOT/$t/admin" "$u"; done
done

# --- REALMWEITE Härtung (nur mit explizitem Flag, siehe Kopf) ------------------
if [[ "$ENABLE_BRUTE_FORCE" == "1" ]]; then
  kc update "realms/$REALM" -s bruteForceProtected=true -s permanentLockout=false -s failureFactor=5 \
    -s waitIncrementSeconds=60 -s maxFailureWaitSeconds=900
  echo "REALMWEIT ($REALM): Brute-Force-Schutz an (5 Fehlversuche, +60 s, max. 15 min, keine Dauersperre)"
fi
if [[ "$SET_PASSWORD_POLICY" == "1" ]]; then
  kc update "realms/$REALM" -s "passwordPolicy=$PASSWORD_POLICY"
  echo "REALMWEIT ($REALM): Passwort-Richtlinie = $PASSWORD_POLICY (gilt bei der nächsten Passwortänderung)"
fi
json_strings() {  # $1 = JSON-Text → alle "…"-Werte zeilenweise (reines Bash, ohne jq)
  local rest=$1
  while [[ $rest =~ \"([^\"]*)\" ]]; do
    echo "${BASH_REMATCH[1]}"
    rest=${rest#*"${BASH_REMATCH[0]}"}
  done
}
if [[ "$REQUIRE_ADMIN_OTP" == "1" ]]; then
  enabled=$(kc get authentication/required-actions/CONFIGURE_TOTP -r "$REALM" --fields enabled --format csv \
    --noquotes 2>/dev/null | head -1 || true)
  if [[ "$enabled" != "true" ]]; then
    kc update authentication/required-actions/CONFIGURE_TOTP -r "$REALM" -s enabled=true
    echo "REALMWEIT ($REALM): Required Action CONFIGURE_TOTP aktiviert"
  fi
  declare -A otp_done=()
  for pair in $ADMINS; do
    IFS=, read -ra users <<< "${pair#*=}"
    for u in "${users[@]}"; do
      [[ -n "${otp_done[$u]:-}" ]] && continue
      otp_done[$u]=1
      uid=$(user_id "$u")
      [[ -z "$uid" ]] && { warn "Benutzer $u nicht gefunden (OTP)"; continue; }
      has_otp=0
      while IFS= read -r a; do [[ "$a" == otp ]] && has_otp=1; done \
        < <(json_strings "$(kc get "users/$uid/credentials" -r "$REALM")")
      if [[ "$has_otp" == 1 ]]; then
        echo "$u: OTP bereits eingerichtet"
        continue
      fi
      actions=()
      while IFS= read -r a; do
        [[ -n "$a" && "$a" != requiredActions ]] && actions+=("$a")
      done < <(json_strings "$(kc get "users/$uid" -r "$REALM" --fields requiredActions)")
      if [[ " ${actions[*]} " == *" CONFIGURE_TOTP "* ]]; then
        echo "$u: CONFIGURE_TOTP bereits gesetzt"
        continue
      fi
      actions+=(CONFIGURE_TOTP)
      list=$(printf '"%s",' "${actions[@]}")
      kc update "users/$uid" -r "$REALM" -s "requiredActions=[${list%,}]"
      echo "$u: OTP bei der nächsten Anmeldung einrichten (CONFIGURE_TOTP)"
    done
  done
fi

ISSUER="${KC_PUBLIC_URL:-$KC_URL}/realms/$REALM"
cat <<INFO

Fertig. Portainer-Stack-Variablen:
  OIDC_ISSUER=$ISSUER
  OIDC_CLIENT_ID=$CLIENT
  OIDC_WEB_CLIENT_ID=$WEB_CLIENT
  OIDC_REQUIRED_ROLE=$ROLE
INFO
if [[ -n "$ADMIN_API_SECRET" ]]; then
  cat <<INFO
  KC_ADMIN_URL=${KC_PUBLIC_URL:-$KC_URL}
  KC_ADMIN_REALM=$REALM
  KC_ADMIN_CLIENT_ID=$ADMIN_API_CLIENT
  KC_ADMIN_CLIENT_SECRET=$ADMIN_API_SECRET
(Secret vertraulich behandeln – nur als Stack-Variable, nicht ins Repository)
INFO
fi
