#!/usr/bin/env bash
# Prüft das Helm-Chart: helm lint, helm template + kubeconform (inkl. CRD-Schemas) für alle Beispiel-Values,
# dazu Negativtests (Template muss mit erwarteter Meldung abbrechen).
# Aufruf: deploy/helm/test-chart.sh   (helm und kubeconform im PATH oder HELM=/KUBECONFORM= setzen)
# Optional: KUBE_VERSIONS="1.30.0 1.34.0", KUBECONFORM_CACHE=<dir>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/fahrzeugbuch"
HELM="${HELM:-helm}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
KUBE_VERSIONS="${KUBE_VERSIONS:-1.30.0 1.34.0}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CACHE="${KUBECONFORM_CACHE:-$OUT/cache}"
mkdir -p "$CACHE"

# Kubernetes-Schemas + CRD-Katalog (VPA, ServiceMonitor, HTTPRoute, Traefik-Middleware, CloudNativePG)
SCHEMA_ARGS=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

pass=0
fail() { echo "FEHLER: $*" >&2; exit 1; }
ok() { echo "  ok  $*"; pass=$((pass + 1)); }

conform() { # $1 = Datei, $2 = Beschriftung
  for kv in $KUBE_VERSIONS; do
    "$KUBECONFORM" -strict -summary -output text -kubernetes-version "$kv" -cache "$CACHE" \
      "${SCHEMA_ARGS[@]}" "$1" >"$OUT/kc.log" 2>&1 || { cat "$OUT/kc.log"; fail "kubeconform $2 (k8s $kv)"; }
    ok "kubeconform $2 (k8s $kv): $(tail -n1 "$OUT/kc.log")"
  done
}

# Minimal-Values für Tests ohne Beispiel-Datei (Chart-Defaults + Pflichtfelder)
cat >"$OUT/min.yaml" <<'EOF'
config:
  OIDC_ISSUER: https://id.example.org/realms/test
database:
  host: db.example
  appPassword: app-secret
  ownerPassword: owner-secret
secrets:
  values:
    ANCHOR_SIGNING_KEY: dGVzdA==
EOF

echo "== helm lint / template / kubeconform =="
VALUES=("$OUT/min.yaml")
for f in "$CHART"/examples/values-*.yaml; do VALUES+=("$f"); done
for f in "${VALUES[@]}"; do
  name="$(basename "$f")"
  "$HELM" lint --strict "$CHART" -f "$f" >"$OUT/lint.log" 2>&1 || { cat "$OUT/lint.log"; fail "helm lint $name"; }
  ok "helm lint --strict $name"
  "$HELM" template fzb "$CHART" -n fahrzeugbuch -f "$f" >"$OUT/$name.rendered.yaml" \
    || fail "helm template $name"
  ok "helm template $name ($(grep -c '^kind:' "$OUT/$name.rendered.yaml") Objekte)"
  conform "$OUT/$name.rendered.yaml" "$name"
done

echo "== Beispiel-Manifest CloudNativePG =="
conform "$CHART/examples/cloudnativepg-cluster.yaml" "cloudnativepg-cluster.yaml"

echo "== Positivtests: Varianten =="
expect_ok() { # $1 = Beschreibung, Rest = helm-Argumente
  local desc="$1"; shift
  "$HELM" template fzb "$CHART" -f "$OUT/min.yaml" "$@" >"$OUT/pos.yaml" 2>"$OUT/pos.err" \
    || { cat "$OUT/pos.err"; fail "unerwarteter Abbruch: $desc"; }
  conform "$OUT/pos.yaml" "$desc"
}
expect_ok "useFileEnv=false (Env-Fallback)" --set secrets.useFileEnv=false
expect_ok "existingSecrets (DB/App/Owner getrennt)" --set database.existingSecret=db --set secrets.existingSecret=app \
  --set database.existingOwnerSecret=db-owner --set database.appPassword= --set database.ownerPassword=
expect_ok "externalRedis + RWX + 3 Replikas" --set stateBackend=redis --set externalRedis.url=redis://redis.infra:6379/0 \
  --set externalRedis.existingSecret=redis \
  --set replicaCount=3 --set 'storage.fs.persistence.accessModes={ReadWriteMany}'
expect_ok "HPA CPU + VPA Off" --set stateBackend=redis --set valkey.enabled=true --set valkey.auth.password=x \
  --set storage.backend=s3 --set storage.s3.bucket=b --set storage.s3.accessKeyId=a --set storage.s3.secretAccessKey=s \
  --set hpa.enabled=true --set vpa.enabled=true --set vpa.updateMode=Off --set database.maxConnections=200

grep -q 'checksum/config' "$OUT/pos.yaml" || fail "checksum-Annotation fehlt"
grep -q 'kind: HorizontalPodAutoscaler' "$OUT/pos.yaml" || fail "HPA fehlt"
grep -q 'kind: PodDisruptionBudget' "$OUT/pos.yaml" || fail "PDB fehlt bei HPA min 2"
ok "HPA/PDB/Checksum vorhanden"

echo "== Negativtests (müssen abbrechen) =="
expect_fail() { # $1 = erwartetes Muster, Rest = helm-Argumente
  local pattern="$1"; shift
  if "$HELM" template fzb "$CHART" -f "$OUT/min.yaml" "$@" >"$OUT/neg.out" 2>&1; then
    fail "kein Abbruch erwartet '$pattern' bei: $*"
  fi
  grep -q -- "$pattern" "$OUT/neg.out" || { cat "$OUT/neg.out"; fail "falsche Meldung (erwartet '$pattern')"; }
  ok "Abbruch: $pattern"
}
expect_fail "erfordern stateBackend=redis" --set replicaCount=2
expect_fail "erfordern stateBackend=redis" --set webConcurrency=4
expect_fail "erfordern stateBackend=redis" --set resources.limits.cpu=2
expect_fail "erfordern stateBackend=redis" --set hpa.enabled=true
expect_fail "ReadWriteMany" --set replicaCount=2 --set stateBackend=redis --set valkey.enabled=true \
  --set valkey.auth.password=x
expect_fail "valkey.enabled=true oder externalRedis" --set stateBackend=redis
expect_fail "Konflikt: HPA skaliert auf CPU" --set stateBackend=redis --set valkey.enabled=true \
  --set valkey.auth.password=x --set storage.backend=s3 --set storage.s3.bucket=b \
  --set storage.s3.accessKeyId=a --set storage.s3.secretAccessKey=s --set hpa.enabled=true \
  --set vpa.enabled=true --set vpa.updateMode=Recreate
expect_fail "Konflikt: HPA skaliert auf Memory" --set stateBackend=redis --set valkey.enabled=true \
  --set valkey.auth.password=x --set storage.backend=s3 --set storage.s3.bucket=b \
  --set storage.s3.accessKeyId=a --set storage.s3.secretAccessKey=s --set hpa.enabled=true \
  --set hpa.targetCPUUtilizationPercentage=null --set hpa.targetMemoryUtilizationPercentage=80 \
  --set vpa.enabled=true --set vpa.updateMode=Initial --set 'vpa.controlledResources={memory}'
expect_fail "DB-Verbindungsbudget überschritten" --set strictBudget=true --set stateBackend=redis \
  --set valkey.enabled=true --set valkey.auth.password=x --set storage.backend=s3 --set storage.s3.bucket=b \
  --set storage.s3.accessKeyId=a --set storage.s3.secretAccessKey=s --set hpa.enabled=true \
  --set hpa.maxReplicas=20 --set webConcurrency=4
expect_fail "verweigert die API den Start" --set stateBackend=redis --set valkey.enabled=true \
  --set valkey.auth.password=x --set storage.backend=s3 --set storage.s3.bucket=b \
  --set storage.s3.accessKeyId=a --set storage.s3.secretAccessKey=s --set hpa.enabled=true --set hpa.maxReplicas=20
expect_fail "webConcurrency=auto erfordert resources.limits.cpu" --set resources.limits.cpu=null
expect_fail "STRICT_CONFIG=1 ohne ANCHOR_SIGNING_KEY" --set secrets.values.ANCHOR_SIGNING_KEY=
expect_fail "config.OIDC_ISSUER fehlt" --set config.OIDC_ISSUER=
expect_fail "database.host fehlt" --set database.host=
expect_fail "preStopSleepSeconds" --set gracefulTimeoutSeconds=40
expect_fail "unsicher" --set config.FORWARDED_ALLOW_IPS=*
expect_fail "storage.s3.bucket fehlt" --set storage.backend=s3
expect_fail "values don't meet the specifications of the schema" --set stateBackend=sqlite
expect_fail "values don't meet the specifications of the schema" --set webConcurrency=zwei
expect_fail "values don't meet the specifications of the schema" --set config.WEB_CONCURRENCY=8
expect_fail "values don't meet the specifications of the schema" --set secrets.values.METRICS_TOKEN=kurz

echo "== $pass Prüfungen bestanden =="
