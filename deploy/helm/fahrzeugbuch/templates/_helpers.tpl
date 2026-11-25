{{/* ---------- Namen und Labels ---------- */}}
{{- define "fahrzeugbuch.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fahrzeugbuch.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "fahrzeugbuch.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fahrzeugbuch.commonLabels" -}}
helm.sh/chart: {{ include "fahrzeugbuch.chart" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fahrzeugbuch
{{- end }}

{{- define "fahrzeugbuch.labels" -}}
app.kubernetes.io/name: {{ include "fahrzeugbuch.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{ include "fahrzeugbuch.commonLabels" . }}
{{- end }}

{{/* Selector-Labels; Aufruf: include "fahrzeugbuch.selectorLabels" (dict "ctx" . "component" "api") */}}
{{- define "fahrzeugbuch.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fahrzeugbuch.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "fahrzeugbuch.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fahrzeugbuch.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "fahrzeugbuch.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag | toString }}
{{- if .Values.image.digest }}
{{- printf "%s:%s@%s" .Values.image.repository $tag .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}
{{- end }}

{{- define "fahrzeugbuch.valkey.image" -}}
{{- $i := .Values.valkey.image }}
{{- if $i.digest }}
{{- printf "%s:%s@%s" $i.repository (toString $i.tag) $i.digest }}
{{- else }}
{{- printf "%s:%s" $i.repository (toString $i.tag) }}
{{- end }}
{{- end }}

{{- define "fahrzeugbuch.valkey.fullname" -}}
{{- printf "%s-valkey" (include "fahrzeugbuch.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fahrzeugbuch.valkey.secretName" -}}
{{- default (include "fahrzeugbuch.valkey.fullname" .) .Values.valkey.auth.existingSecret }}
{{- end }}

{{/* ---------- Mengen-Helfer ---------- */}}
{{/* CPU-Angabe ("500m", "1", 1.5) → Millicores (int als String) */}}
{{- define "fahrzeugbuch.cpuMilli" -}}
{{- $v := toString . }}
{{- if hasSuffix "m" $v }}
{{- trimSuffix "m" $v | atoi }}
{{- else }}
{{- mulf (float64 $v) 1000 | ceil | int }}
{{- end }}
{{- end }}

{{/* maximale Worker-Zahl je Pod (für Guards und Verbindungsbudget); "auto" wie app/config.py:
     min(floor(2 × CPU-Quota), 16), mind. 1 – CPU-Quota = limits.cpu (mit VPA: maxAllowed.cpu × limits/requests) */}}
{{- define "fahrzeugbuch.workersMax" -}}
{{- $wc := toString .Values.webConcurrency }}
{{- if eq $wc "auto" }}
{{- $lim := dig "limits" "cpu" "" (.Values.resources | default dict) | toString }}
{{- if not $lim }}
{{- fail "webConcurrency=auto erfordert resources.limits.cpu (WEB_CONCURRENCY wird aus cgroup cpu.max abgeleitet; ohne Limit wären es alle Kerne des Knotens). Limit setzen oder webConcurrency als Zahl angeben." }}
{{- end }}
{{- $limM := include "fahrzeugbuch.cpuMilli" $lim | atoi }}
{{- $v := .Values.vpa }}
{{- if and $v.enabled (ne (toString $v.updateMode) "Off") (has "cpu" $v.controlledResources) (eq (toString $v.controlledValues) "RequestsAndLimits") }}
{{- $maxA := dig "maxAllowed" "cpu" "" ($v | default dict) | toString }}
{{- if not $maxA }}
{{- fail "vpa: mit webConcurrency=auto und controlledValues=RequestsAndLimits ist vpa.maxAllowed.cpu Pflicht (bestimmt die maximale Worker-Zahl und damit das DB-Verbindungsbudget)." }}
{{- end }}
{{- $reqM := include "fahrzeugbuch.cpuMilli" (dig "requests" "cpu" $lim (.Values.resources | default dict)) | atoi }}
{{- $limM = div (mul (include "fahrzeugbuch.cpuMilli" $maxA | atoi) $limM) (max 1 $reqM) }}
{{- end }}
{{- max 1 (min 16 (div (mul 2 $limM) 1000)) }}
{{- else }}
{{- atoi $wc }}
{{- end }}
{{- end }}

{{- define "fahrzeugbuch.replicasMax" -}}
{{- if .Values.hpa.enabled }}{{ int .Values.hpa.maxReplicas }}{{ else }}{{ int .Values.replicaCount }}{{ end }}
{{- end }}

{{- define "fahrzeugbuch.replicasMin" -}}
{{- if .Values.hpa.enabled }}{{ int .Values.hpa.minReplicas }}{{ else }}{{ int .Values.replicaCount }}{{ end }}
{{- end }}

{{- define "fahrzeugbuch.fsRWX" -}}
{{- if and (eq .Values.storage.backend "fs") .Values.storage.fs.persistence.enabled (has "ReadWriteMany" .Values.storage.fs.persistence.accessModes) }}true{{ end }}
{{- end }}

{{- define "fahrzeugbuch.strategyType" -}}
{{- $t := .Values.updateStrategy.type }}
{{- if eq $t "auto" }}
{{- if and (eq .Values.storage.backend "fs") .Values.storage.fs.persistence.enabled (not (include "fahrzeugbuch.fsRWX" .)) }}Recreate{{ else }}RollingUpdate{{ end }}
{{- else }}{{ $t }}{{ end }}
{{- end }}

{{- define "fahrzeugbuch.surge" -}}
{{- if eq (include "fahrzeugbuch.strategyType" .) "RollingUpdate" }}{{ int .Values.updateStrategy.maxSurge }}{{ else }}0{{ end }}
{{- end }}

{{/* Verbindungsbudget als dict (YAML) */}}
{{- define "fahrzeugbuch.budget" -}}
{{- $replicas := include "fahrzeugbuch.replicasMax" . | atoi }}
{{- $surge := include "fahrzeugbuch.surge" . | atoi }}
{{- $workers := include "fahrzeugbuch.workersMax" . | atoi }}
{{- $perWorker := add (int .Values.database.pool.size) (int .Values.database.pool.maxOverflow) }}
{{- $reserved := int .Values.database.reservedConnections }}
{{- $total := add (mul (add $replicas $surge) $workers $perWorker) $reserved }}
{{- $serverTotal := add (mul $replicas $workers $perWorker) $reserved }}
replicas: {{ $replicas }}
surge: {{ $surge }}
workers: {{ $workers }}
perWorker: {{ $perWorker }}
reserved: {{ $reserved }}
total: {{ $total }}
max: {{ int .Values.database.maxConnections }}
ok: {{ le $total (int .Values.database.maxConnections) }}
serverTotal: {{ $serverTotal }}
serverOk: {{ le $serverTotal (int .Values.database.maxConnections) }}
{{- end }}

{{/* ---------- Hosts ---------- */}}
{{- define "fahrzeugbuch.allowedHosts" -}}
{{- if .Values.config.ALLOWED_HOSTS }}
{{- .Values.config.ALLOWED_HOSTS }}
{{- else }}
{{- $hosts := list }}
{{- if .Values.ingress.enabled }}
{{- range .Values.ingress.hosts }}{{ $hosts = append $hosts .host }}{{ end }}
{{- end }}
{{- if .Values.httpRoute.enabled }}
{{- range .Values.httpRoute.hostnames }}{{ $hosts = append $hosts . }}{{ end }}
{{- end }}
{{- $hosts = append $hosts "localhost" }}
{{- $hosts | uniq | join "," }}
{{- end }}
{{- end }}

{{/* ---------- Datenbank-/Redis-URLs (ohne Passwort; der Server setzt *_PASSWORD(_FILE) ein) ---------- */}}
{{- define "fahrzeugbuch.db.query" -}}
{{- $p := list (printf "sslmode=%s" .Values.database.sslmode) }}
{{- range $k, $v := .Values.database.extraParams }}{{ $p = append $p (printf "%s=%s" $k (urlquery (toString $v))) }}{{ end }}
{{- join "&" $p }}
{{- end }}

{{/* Aufruf: dict "ctx" . "user" u ["target" "migration"] */}}
{{- define "fahrzeugbuch.db.url" -}}
{{- $d := .ctx.Values.database }}
{{- $mig := eq (toString .target) "migration" }}
{{- $host := ternary (default $d.host $d.migrationHost) $d.host $mig }}
{{- $port := ternary (default $d.port $d.migrationPort) $d.port $mig }}
{{- printf "%s://%s@%s:%v/%s?%s" $d.driver (urlquery .user) $host $port $d.name (include "fahrzeugbuch.db.query" .ctx) }}
{{- end }}

{{- define "fahrzeugbuch.redis.url" -}}
{{- if .Values.valkey.enabled }}
{{- printf "redis://%s:6379/%v" (include "fahrzeugbuch.valkey.fullname" .) .Values.valkey.database }}
{{- else }}
{{- .Values.externalRedis.url }}
{{- end }}
{{- end }}

{{/* ---------- Geheimnisse ----------
secretItems liefern eine YAML-Liste {env: NAME, secret: <Secret>, key: <Schlüssel>}:
useFileEnv=true → Datei <mountPath>/NAME + Env NAME_FILE (projected Volume), sonst Env NAME per secretKeyRef.
Passwörter werden getrennt von den URLs übergeben (DATABASE_PASSWORD, MIGRATION_DATABASE_PASSWORD,
REDIS_PASSWORD) – der Server setzt sie in DATABASE_URL/MIGRATION_DATABASE_URL/REDIS_URL ein.
*/}}
{{- define "fahrzeugbuch.api.secretItems" -}}
{{- $full := include "fahrzeugbuch.fullname" . }}
{{- $items := list }}
{{- if .Values.secrets.existingSecret }}
{{- range .Values.secrets.existingSecretKeys }}
{{- $items = append $items (dict "env" . "secret" $.Values.secrets.existingSecret "key" .) }}
{{- end }}
{{- else }}
{{- range $k, $v := .Values.secrets.values }}
{{- if $v }}{{ $items = append $items (dict "env" $k "secret" $full "key" $k) }}{{ end }}
{{- end }}
{{- end }}
{{- $db := .Values.database }}
{{- if $db.existingSecret }}
{{- $items = append $items (dict "env" "DATABASE_PASSWORD" "secret" $db.existingSecret "key" $db.appPasswordKey) }}
{{- else }}
{{- $items = append $items (dict "env" "DATABASE_PASSWORD" "secret" $full "key" "DATABASE_PASSWORD") }}
{{- end }}
{{- if eq .Values.stateBackend "redis" }}
{{- if .Values.valkey.enabled }}
{{- $items = append $items (dict "env" "REDIS_PASSWORD" "secret" (include "fahrzeugbuch.valkey.secretName" .) "key" .Values.valkey.auth.existingSecretKey) }}
{{- else if .Values.externalRedis.existingSecret }}
{{- $items = append $items (dict "env" "REDIS_PASSWORD" "secret" .Values.externalRedis.existingSecret "key" .Values.externalRedis.passwordKey) }}
{{- end }}
{{- end }}
{{- if eq .Values.storage.backend "s3" }}
{{- $s3 := .Values.storage.s3 }}
{{- if $s3.existingSecret }}
{{- $items = append $items (dict "env" "S3_ACCESS_KEY_ID" "secret" $s3.existingSecret "key" $s3.accessKeyIdKey) }}
{{- $items = append $items (dict "env" "S3_SECRET_ACCESS_KEY" "secret" $s3.existingSecret "key" $s3.secretAccessKeyKey) }}
{{- else }}
{{- $items = append $items (dict "env" "S3_ACCESS_KEY_ID" "secret" $full "key" "S3_ACCESS_KEY_ID") }}
{{- $items = append $items (dict "env" "S3_SECRET_ACCESS_KEY" "secret" $full "key" "S3_SECRET_ACCESS_KEY") }}
{{- end }}
{{- end }}
{{- toYaml $items }}
{{- end }}

{{/* Inhalt (stringData) des vom Chart erzeugten App-Secrets als YAML-dict */}}
{{- define "fahrzeugbuch.api.secretData" -}}
{{- $data := dict }}
{{- if not .Values.secrets.existingSecret }}
{{- range $k, $v := .Values.secrets.values }}{{ if $v }}{{ $_ := set $data $k (toString $v) }}{{ end }}{{ end }}
{{- end }}
{{- if not .Values.database.existingSecret }}
{{- $_ := set $data "DATABASE_PASSWORD" (toString .Values.database.appPassword) }}
{{- end }}
{{- if and (eq .Values.storage.backend "s3") (not .Values.storage.s3.existingSecret) }}
{{- $_ := set $data "S3_ACCESS_KEY_ID" (toString .Values.storage.s3.accessKeyId) }}
{{- $_ := set $data "S3_SECRET_ACCESS_KEY" (toString .Values.storage.s3.secretAccessKey) }}
{{- end }}
{{- toYaml $data }}
{{- end }}

{{/* Geheimnisse des Migrations-Jobs: Owner- und App-Passwort */}}
{{- define "fahrzeugbuch.migrate.secretItems" -}}
{{- $db := .Values.database }}
{{- $items := list }}
{{- if $db.existingSecret }}
{{- $items = append $items (dict "env" "MIGRATION_DATABASE_PASSWORD" "secret" (default $db.existingSecret $db.existingOwnerSecret) "key" $db.ownerPasswordKey) }}
{{- $items = append $items (dict "env" "DATABASE_PASSWORD" "secret" $db.existingSecret "key" $db.appPasswordKey) }}
{{- else }}
{{- $mig := printf "%s-migrate" (include "fahrzeugbuch.fullname" .) }}
{{- $items = append $items (dict "env" "MIGRATION_DATABASE_PASSWORD" "secret" $mig "key" "MIGRATION_DATABASE_PASSWORD") }}
{{- $items = append $items (dict "env" "DATABASE_PASSWORD" "secret" $mig "key" "DATABASE_PASSWORD") }}
{{- end }}
{{- toYaml $items }}
{{- end }}

{{/* Env-Liste aus secretItems; Aufruf: dict "items" <liste> "mountPath" p "useFile" bool */}}
{{- define "fahrzeugbuch.secretEnv" -}}
{{- range .items }}
{{- if $.useFile }}
- name: {{ printf "%s_FILE" .env }}
  value: {{ printf "%s/%s" $.mountPath .env | quote }}
{{- else }}
- name: {{ .env }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ .key }}
{{- end }}
{{- end }}
{{- end }}

{{/* projected-Volume-Quellen für Datei-Secrets; Aufruf wie secretEnv */}}
{{- define "fahrzeugbuch.secretSources" -}}
{{- $bySecret := dict }}
{{- range .items }}
{{- $l := get $bySecret .secret | default list }}
{{- $_ := set $bySecret .secret (append $l (dict "key" .key "path" .env)) }}
{{- end }}
{{- range $name, $list := $bySecret }}
- secret:
    name: {{ $name }}
    items:
      {{- toYaml $list | nindent 6 }}
{{- end }}
{{- end }}

{{- define "fahrzeugbuch.hasFileSecrets" -}}
{{- if and .useFile .items }}true{{ end }}
{{- end }}

{{/* ---------- NetworkPolicy-Ziel → egress-Regel ---------- */}}
{{- define "fahrzeugbuch.np.egressRule" -}}
{{- $t := . }}
{{- if or $t.cidrs $t.namespaceSelector $t.podSelector }}
- to:
    {{- range $t.cidrs }}
    - ipBlock:
        cidr: {{ . }}
    {{- end }}
    {{- if or $t.namespaceSelector $t.podSelector }}
    - {{- with $t.namespaceSelector }}
      namespaceSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $t.podSelector }}
      podSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    {{- end }}
  ports:
    {{- range $t.ports }}
    - protocol: TCP
      port: {{ . }}
    {{- end }}
{{- end }}
{{- end }}
