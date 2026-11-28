CrowdSec für das Fahrzeugbuch (Sicherheits-Log der API, Logger fahrzeugbuch.security)
=========================================================================================
Die API schreibt je Sicherheits-Ereignis eine JSON-Zeile nach stderr (docker logs fahrzeugbuch-api), z. B.
  {"ts":"…","logger":"fahrzeugbuch.security","event":"auth_failed","ip":"198.51.100.7","path":"/api/me",…}
Ereignisse: auth_failed, auth_missing, rate_limited, brute_force_block, forbidden_tenant, admin_action,
web_only_violation, upload_rejected, integrity_failed, integrity_full_overdue, verify_full_busy, config_warning,
cors_rejected, host_rejected, forbidden_role. auth_missing (fehlendes/kaputtes Token) zählt bewusst nicht für
Sperren – nur auth_failed (gefälschtes, abgelaufenes, fremdes Token). "path" ist URL-kodiert (ohne Query, nie ").

Dateien
  acquis-fahrzeugbuch.yaml       → /etc/crowdsec/acquis.d/       (liest die Container-Logs über Docker)
  fahrzeugbuch-security-logs.yaml→ /etc/crowdsec/parsers/s01-parse/
  fahrzeugbuch-bf.yaml           → /etc/crowdsec/scenarios/
Danach: sudo systemctl reload crowdsec ; cscli parsers list | grep fahrzeugbuch ; cscli scenarios list
Test:   cscli explain --file <(docker logs fahrzeugbuch-api 2>&1 | grep fahrzeugbuch.security) \
          --type fahrzeugbuch-security

Wichtig
- Sperren muss ein Bouncer AM RAND (OPNsense-Firewall-Bouncer bzw. caddy-crowdsec-bouncer): die API sieht
  die echte Client-IP nur, weil der Proxy X-Forwarded-For setzt.
- Die IP im Log ist die von der API ermittelte Client-IP (FORWARDED_ALLOW_IPS korrekt setzen!). Eigene
  Netze in /etc/crowdsec/parsers/s02-enrich/whitelists.yaml (oder SECURITY_ALLOWLIST der API) ausnehmen.
