# Helm-Chart Fahrzeugbuch

Ein Image (API + Web-Frontend, uvicorn auf Port 8000), Migration als Helm-Hook, optional Valkey, HPA/VPA,
NetworkPolicy, ServiceMonitor. **PostgreSQL betreibt das Chart nicht** – CloudNativePG
([`examples/cloudnativepg-cluster.yaml`](examples/cloudnativepg-cluster.yaml)) oder eine externe DB. Keine Subcharts.

| Datei | Zweck |
|---|---|
| `values.yaml` / `values.schema.json` | alle Optionen mit Kommentaren / Validierung |
| `examples/values-single.yaml` | 1 Pod, RWO-Volume, vertikal per VPA |
| `examples/values-scale.yaml` | HPA 2–10, Valkey, S3/MinIO, PDB, NetworkPolicy, ServiceMonitor, PgBouncer |
| `examples/values-proxmox-k3s.yaml` | k3s: Traefik, Longhorn RWX, PostgreSQL auf der Docker-VM |
| `../test-chart.sh` | lint + template + kubeconform + Negativtests (auch in der CI) |

## Installation

```bash
NS=fahrzeugbuch; kubectl create namespace $NS
# Geheimnisse (Passwörter: openssl rand -hex 32)
kubectl -n $NS create secret generic fahrzeugbuch-app \
  --from-literal=ANCHOR_SIGNING_KEY="$(openssl rand -base64 32)"      # separat sichern!
kubectl -n $NS create secret generic fahrzeugbuch-db \
  --from-literal=app-password="$(openssl rand -hex 32)" --from-literal=owner-password="<Owner-Passwort>"
kubectl -n $NS create secret generic fahrzeugbuch-valkey --from-literal=valkey-password="$(openssl rand -hex 32)"

helm upgrade --install fahrzeugbuch deploy/helm/fahrzeugbuch -n $NS \
  -f deploy/helm/fahrzeugbuch/examples/values-single.yaml
```

Pflicht: `config.OIDC_ISSUER`, `database.host`, DB-Passwörter (`database.existingSecret`, Schlüssel
`app-password`/`owner-password`, Owner optional getrennt in `database.existingOwnerSecret`), bei
`STRICT_CONFIG=1` (Default) `ANCHOR_SIGNING_KEY`. Weitere App-Geheimnisse (`KC_ADMIN_CLIENT_SECRET`, `VLLM_API_KEY`,
`N8N_WEBHOOK_SECRET`, `METRICS_TOKEN`) ins App-Secret und in `secrets.existingSecretKeys` eintragen.

Geheimnisse kommen als Dateien (`/run/secrets/fahrzeugbuch/<NAME>` + Env `<NAME>_FILE`); URLs enthalten kein
Passwort – der Server setzt `DATABASE_PASSWORD`, `MIGRATION_DATABASE_PASSWORD`, `REDIS_PASSWORD` ein.
`secrets.useFileEnv=false` übergibt sie stattdessen als Env (secretKeyRef). Klartext-Werte in den Values
(`secrets.values`, `database.appPassword` …) nur für Tests. Änderungen an existierenden Secrets: `kubectl rollout restart`.

Wichtig hinter Ingress/Gateway: `config.FORWARDED_ALLOW_IPS` = Pod-CIDR des Ingress-Controllers (k3s
`10.42.0.0/16`), sonst teilen sich alle Clients eine IP (Rate-Limits). `ALLOWED_HOSTS` wird aus den Ingress-Hosts
gebildet. Body-Grösse 8 MiB für Belege: nginx-Annotation `proxy-body-size: 8m` bzw. `ingress.traefikMiddleware`.

## Migration

`python -m app.migrate` läuft als Job-Hook (`pre-install,pre-upgrade`, vor allen anderen Ressourcen) mit der
Owner-Rolle; die App-Pods erhalten nur die App-Rolle `fahrzeugbuch_app` (`AUTO_MIGRATE=0`). Bei Erfolg löscht Helm
Job, Hook-Secret und Hook-ServiceAccount; ein Fehler bricht `helm upgrade` ab, die alten Pods laufen weiter
(`kubectl logs job/<release>-fahrzeugbuch-migrate`). Argo CD führt die Hooks als PreSync aus.
Mit PgBouncer: `database.migrationHost` direkt auf die Primary (`<cluster>-rw`).
`/health/ready` meldet 503, solange das Schema älter als der Stand des Images ist (`migration_pending`) oder
neuer und nicht als kompatibel markiert (`schema_newer`); ein Valkey-Ausfall macht Pods nicht unbereit
(200, `"degraded": true` – Rate-Limits dann fail-open, Sperren je Pod). Der Migrationslauf eines älteren Images
ändert einen neueren Stand nie: kompatibel → Exit 0 ohne Änderung, sonst Abbruch.

## Skalieren

**Vertikal** (`values-single.yaml`): `webConcurrency: auto` → Worker = min(⌊2 × limits.cpu⌋, 16), bei jedem Start
neu. Mehr CPU → mehr Worker; VPA (`updateMode` Off/Initial/Recreate/InPlaceOrRecreate) hebt Requests und Limits an
(`controlledValues: RequestsAndLimits`, Obergrenze `vpa.maxAllowed`). Mehr als 1 Worker braucht
`stateBackend: redis` (Valkey); ohne Valkey `limits.cpu < 1` bzw. `webConcurrency: 1`.

**Horizontal** (`values-scale.yaml`): HPA (`hpa.*`, scaleDown stabilisiert) oder `replicaCount > 1` erfordert
`stateBackend: redis` **und** `storage.backend: s3` oder ein `ReadWriteMany`-Volume – sonst bricht das Template ab.
PDB (`minAvailable: 1`) wird ab 2 Replikas angelegt. HPA und VPA nie auf derselben Ressource (Template bricht ab);
üblich: HPA auf CPU, VPA nur `memory` oder `updateMode: Off` (Empfehlung).

Rollout: RollingUpdate `maxUnavailable 0 / maxSurge 1`; mit RWO-Volume automatisch `Recreate` (sonst hinge der
neue Pod am Volume). Shutdown: preStop 5 s + `GRACEFUL_TIMEOUT_S` 25 s ≤ `terminationGracePeriodSeconds` 30.

## Verbindungsbudget

```
(maxReplicas + maxSurge) × Worker × (DB_POOL_SIZE + DB_MAX_OVERFLOW) + reservedConnections ≤ database.maxConnections
```

NOTES zeigt die Rechnung; `strictBudget: true` bricht bei Überschreitung ab. Die API prüft beim Start dasselbe
(ohne Surge, `REPLICAS_HINT` = max. Replikas) und startet mit `STRICT_CONFIG=1` nicht – das Chart bricht dann schon
beim Rendern ab. Viele Pods: CloudNativePG-Pooler (PgBouncer, Transaction-Mode) + `database.disablePreparedStatements:
true`, `database.maxConnections` = `max_client_conn` des Poolers.

## Upgrade / Rollback

```bash
helm upgrade fahrzeugbuch … -f values.yaml          # Migration → Rollout
helm history fahrzeugbuch -n $NS; helm rollback fahrzeugbuch <rev> -n $NS
```

Ablauf `helm upgrade`: Hook-Job migriert (pre-upgrade) → Rolling Update (`maxUnavailable 0`). Während des
Rollouts laufen alte Pods schon auf dem neuen Schema. Sie bleiben bereit, wenn der neue Stand für sie
**kompatibel** ist:

| Neue Migration | alte Pods während Rollout / nach `helm rollback` |
|---|---|
| `compatible_with_previous = True` (rein additiv, z. B. neue Tabelle/Index, nullable Spalte ausserhalb der Snapshots) | bereit: der Migrationslauf vermerkt die kompatiblen älteren Stände am Tabellenkommentar von `alembic_version`, das alte Image liest ihn (`database: compatible_newer`, `degraded: true`) |
| `False` (z. B. 0005 `vehicles.vin`: altes Image kennt `vin` nicht) | `/health/ready` 503 `schema_newer` → kurzer Ausfall bis die neuen Pods bereit sind; Rollback siehe unten |

`helm rollback` setzt nur Kubernetes-Ressourcen zurück, **nicht das DB-Schema** (keine Downgrade-Migration; der
Migrations-Hook läuft bei `rollback` nicht). Danach:

1. Ist der neue Stand als kompatibel vermerkt → nichts zu tun, die alten Pods werden bereit.
2. Sonst, wenn das ältere Image auf dem neuen Schema trotzdem laufen darf (Fachentscheid; Release-Notes der Migration
   prüfen): `helm upgrade <release> <chart-version des Rollbacks> --reuse-values
   --set-string config.SCHEMA_COMPATIBLE_NEWER=<neue Revision>` (bzw. `"*"`); Readiness → 200, `helm upgrade` mit dem
   älteren Chart bricht im Migrations-Job dann nicht ab. Nach dem nächsten Upgrade wieder leeren.
3. Sonst DB aus dem Backup vor dem Upgrade zurückspielen. Deshalb vor jedem Upgrade sichern.

Neue Migrationen: `compatible_with_previous` im Revisionsmodul bewusst setzen (Vorlage `alembic/script.py.mako`,
Default `False`). Das Beleg-PVC bleibt bei `helm uninstall` erhalten (`storage.fs.persistence.retain`).

## Backup

Gemeinsam und zeitnah: **Datenbank** (CloudNativePG Barman-Cloud bzw. `pg_dump` als Owner) **und Belege**
(S3-Bucket mit Versionierung/Replikation bzw. PVC-Snapshot/Longhorn-Backup). **`ANCHOR_SIGNING_KEY`** separat und
offline aufbewahren – ohne ihn lassen sich neue Anker nicht mehr mit demselben Schlüssel signieren; nach einem
Wechsel alte Public Keys in `config.ANCHOR_PUBLIC_KEYS`. Signierte Anker zusätzlich extern archivieren
(`GET /api/t/<mandant>/audit/anchors`).

## Tests

```bash
deploy/helm/test-chart.sh   # helm + kubeconform im PATH (oder HELM=/KUBECONFORM=)
```
