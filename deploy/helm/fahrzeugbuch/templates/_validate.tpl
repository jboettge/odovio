{{/* Konsistenzprüfungen – bricht helm install/upgrade/template mit klarer Meldung ab */}}
{{- define "fahrzeugbuch.validate" -}}
{{- $v := .Values }}
{{- if not $v.config.OIDC_ISSUER }}
{{- fail "config.OIDC_ISSUER fehlt (z. B. https://id.example.org/realms/<realm>)." }}
{{- end }}
{{- if not $v.database.host }}
{{- fail "database.host fehlt (PostgreSQL wird nicht vom Chart betrieben – CloudNativePG-Service oder externe DB angeben)." }}
{{- end }}
{{- if not $v.database.existingSecret }}
{{- if not $v.database.appPassword }}
{{- fail "database.existingSecret oder database.appPassword angeben (empfohlen: existingSecret)." }}
{{- end }}
{{- if and $v.migration.enabled (not $v.database.ownerPassword) }}
{{- fail "database.ownerPassword fehlt (Migrations-Job braucht die Owner-Rolle) – oder database.existingSecret verwenden." }}
{{- end }}
{{- end }}

{{/* ---- NetworkPolicy (Standard an): Ziele für DB und Issuer Pflicht ---- */}}
{{- if $v.networkPolicy.enabled }}
{{- $e := $v.networkPolicy.egress }}
{{- if not (or $e.database.cidrs $e.database.namespaceSelector $e.database.podSelector) }}
{{- fail "networkPolicy.enabled (Standard): networkPolicy.egress.database setzen (cidrs, namespaceSelector oder podSelector) – sonst ist die Datenbank gesperrt. Ohne NetworkPolicy: networkPolicy.enabled=false." }}
{{- end }}
{{- if not (or $e.oidc.cidrs $e.oidc.namespaceSelector $e.oidc.podSelector) }}
{{- fail "networkPolicy.enabled (Standard): networkPolicy.egress.oidc setzen (Keycloak/Issuer: cidrs, namespaceSelector oder podSelector) – sonst schlagen Anmeldungen fehl. Ohne NetworkPolicy: networkPolicy.enabled=false." }}
{{- end }}
{{- end }}

{{/* ---- Skalierung: gemeinsamer Zustand und Speicher ---- */}}
{{- $replicasMax := include "fahrzeugbuch.replicasMax" . | atoi }}
{{- $workers := include "fahrzeugbuch.workersMax" . | atoi }}
{{- if and (ne $v.stateBackend "redis") (or (gt $replicasMax 1) (gt $workers 1)) }}
{{- fail (printf "Mehrere Prozesse (max. %d Replikas × %d Worker) erfordern stateBackend=redis mit valkey.enabled=true oder externalRedis – Rate-Limits/Sperren liegen sonst je Prozess im Speicher. Alternativ replicaCount=1, hpa.enabled=false und webConcurrency=1 (bzw. resources.limits.cpu ≤ 1)." $replicasMax $workers) }}
{{- end }}
{{- if eq $v.stateBackend "redis" }}
{{- if not (or $v.valkey.enabled $v.externalRedis.url) }}
{{- fail "stateBackend=redis: valkey.enabled=true oder externalRedis.url (ohne Passwort; Passwort über externalRedis.existingSecret) setzen." }}
{{- end }}
{{- if and $v.valkey.enabled (not $v.valkey.auth.existingSecret) (not $v.valkey.auth.password) }}
{{- fail "valkey.enabled: valkey.auth.password oder valkey.auth.existingSecret setzen (openssl rand -hex 32)." }}
{{- end }}
{{- end }}
{{- if gt $replicasMax 1 }}
{{- if eq $v.storage.backend "fs" }}
{{- if not (include "fahrzeugbuch.fsRWX" .) }}
{{- fail (printf "Bis zu %d Replikas mit storage.backend=fs erfordern ein persistentes Volume mit ReadWriteMany (storage.fs.persistence.accessModes: [ReadWriteMany], z. B. Longhorn RWX/NFS) – oder storage.backend=s3." $replicasMax) }}
{{- end }}
{{- end }}
{{- end }}
{{- if eq $v.storage.backend "s3" }}
{{- if not $v.storage.s3.bucket }}
{{- fail "storage.backend=s3: storage.s3.bucket fehlt." }}
{{- end }}
{{- if and (not $v.storage.s3.existingSecret) (not (and $v.storage.s3.accessKeyId $v.storage.s3.secretAccessKey)) }}
{{- fail "storage.backend=s3: storage.s3.existingSecret oder accessKeyId/secretAccessKey setzen." }}
{{- end }}
{{- end }}

{{/* ---- HPA/VPA ---- */}}
{{- if $v.hpa.enabled }}
{{- if gt (int $v.hpa.minReplicas) (int $v.hpa.maxReplicas) }}
{{- fail "hpa.minReplicas > hpa.maxReplicas." }}
{{- end }}
{{- if not (or $v.hpa.targetCPUUtilizationPercentage $v.hpa.targetMemoryUtilizationPercentage $v.hpa.customMetrics) }}
{{- fail "hpa.enabled: mindestens eine Metrik (targetCPU…/targetMemory…/customMetrics) angeben." }}
{{- end }}
{{- if and $v.hpa.targetCPUUtilizationPercentage (not (dig "requests" "cpu" "" ($v.resources | default dict))) }}
{{- fail "hpa.targetCPUUtilizationPercentage erfordert resources.requests.cpu." }}
{{- end }}
{{- if and $v.hpa.targetMemoryUtilizationPercentage (not (dig "requests" "memory" "" ($v.resources | default dict))) }}
{{- fail "hpa.targetMemoryUtilizationPercentage erfordert resources.requests.memory." }}
{{- end }}
{{- if and $v.vpa.enabled (ne (toString $v.vpa.updateMode) "Off") }}
{{- if and $v.hpa.targetCPUUtilizationPercentage (has "cpu" $v.vpa.controlledResources) }}
{{- fail "Konflikt: HPA skaliert auf CPU und VPA (updateMode≠Off) steuert CPU. VPA auf memory beschränken (vpa.controlledResources: [memory]), HPA auf customMetrics umstellen oder vpa.updateMode=Off (nur Empfehlung)." }}
{{- end }}
{{- if and $v.hpa.targetMemoryUtilizationPercentage (has "memory" $v.vpa.controlledResources) }}
{{- fail "Konflikt: HPA skaliert auf Memory und VPA (updateMode≠Off) steuert Memory. Ressource nur einem Autoscaler zuordnen oder vpa.updateMode=Off." }}
{{- end }}
{{- end }}
{{- end }}

{{/* ---- Verbindungsbudget ---- */}}
{{- $b := include "fahrzeugbuch.budget" . | fromYaml }}
{{- if and $v.strictBudget (not $b.ok) }}
{{- fail (printf "DB-Verbindungsbudget überschritten: (%v Replikas + %v Surge) × %v Worker × %v (DB_POOL_SIZE+DB_MAX_OVERFLOW) + %v Reserve = %v > database.maxConnections %v. Pool/Worker/maxReplicas senken, PgBouncer (CloudNativePG Pooler) einsetzen oder max_connections erhöhen." $b.replicas $b.surge $b.workers $b.perWorker $b.reserved $b.total $b.max) }}
{{- end }}

{{- if and (eq (toString $v.config.STRICT_CONFIG) "1") (not $b.serverOk) }}
{{- fail (printf "DB-Verbindungsbudget: %v Replikas (REPLICAS_HINT) × %v Worker × %v + %v Reserve = %v > PG_MAX_CONNECTIONS %v – mit STRICT_CONFIG=1 verweigert die API den Start. Pool/Worker/maxReplicas senken oder database.maxConnections (Pooler) anpassen." $b.replicas $b.workers $b.perWorker $b.reserved $b.serverTotal $b.max) }}
{{- end }}

{{/* ---- Shutdown ---- */}}
{{- if gt (add (int $v.preStopSleepSeconds) (int $v.gracefulTimeoutSeconds)) (int $v.terminationGracePeriodSeconds) }}
{{- fail "preStopSleepSeconds + gracefulTimeoutSeconds muss ≤ terminationGracePeriodSeconds sein (sonst SIGKILL vor Ende des Graceful Shutdown)." }}
{{- end }}
{{- if or (hasKey $v.config "DATABASE_URL") (hasKey $v.config "REDIS_URL") (hasKey $v.config "REPLICAS_HINT") }}
{{- fail "config.DATABASE_URL/REDIS_URL/REPLICAS_HINT werden vom Chart gesetzt (database.*, valkey/externalRedis, replicaCount/hpa)." }}
{{- end }}

{{/* ---- Sicherheit ---- */}}
{{- if eq (toString $v.config.STRICT_CONFIG) "1" }}
{{- $hasAnchor := false }}
{{- if $v.secrets.existingSecret }}{{ $hasAnchor = has "ANCHOR_SIGNING_KEY" $v.secrets.existingSecretKeys }}{{ else }}{{ $hasAnchor = not (empty $v.secrets.values.ANCHOR_SIGNING_KEY) }}{{ end }}
{{- if not $hasAnchor }}
{{- fail "STRICT_CONFIG=1 ohne ANCHOR_SIGNING_KEY: die API würde nicht starten. secrets.values.ANCHOR_SIGNING_KEY bzw. secrets.existingSecret + existingSecretKeys [ANCHOR_SIGNING_KEY] setzen (oder config.STRICT_CONFIG=\"0\")." }}
{{- end }}
{{- end }}
{{- if or (eq (toString $v.config.FORWARDED_ALLOW_IPS) "*") (eq (toString $v.config.SECURITY_ALLOWLIST) "*") }}
{{- fail "FORWARDED_ALLOW_IPS/SECURITY_ALLOWLIST=* ist unsicher (IP-Sperren umgehbar) – Pod-CIDR des Ingress-Controllers angeben." }}
{{- end }}
{{- if $v.serviceMonitor.enabled }}
{{- $hasToken := or $v.serviceMonitor.tokenSecret.name (and (not $v.secrets.existingSecret) $v.secrets.values.METRICS_TOKEN) (and $v.secrets.existingSecret (has "METRICS_TOKEN" $v.secrets.existingSecretKeys)) }}
{{- if not (or $hasToken $v.config.METRICS_ALLOW) }}
{{- fail "serviceMonitor.enabled: METRICS_TOKEN (secrets) bzw. serviceMonitor.tokenSecret oder config.METRICS_ALLOW setzen – /metrics ist sonst gesperrt." }}
{{- end }}
{{- end }}
{{- end }}
