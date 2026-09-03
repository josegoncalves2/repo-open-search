#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Ativa TODAS as features oficiais (alerting, anomaly detection, ML Commons,
# ISM, observability, notifications, security analytics, query workbench)
# via API de cluster settings.  Idempotente - pode rodar quantas vezes quiser.
# ---------------------------------------------------------------------------
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9200}"
OS_ADMIN_USER="${OS_ADMIN_USER:-admin}"
OS_ADMIN_PASS="${OS_ADMIN_PASS:?defina OS_ADMIN_PASS}"

api() {
  curl -sk -u "${OS_ADMIN_USER}:${OS_ADMIN_PASS}" \
       -H 'Content-Type: application/json' "$@"
}

put_persistent() {
  local key="$1" value="$2"
  api -XPUT "${OS_URL}/_cluster/settings" -d "{
    \"persistent\": { \"${key}\": ${value} }
  }" | head -c 200; echo
}

echo "==> Ativando plugins oficiais como cluster settings persistentes"
put_persistent "plugins.alerting.enabled"               "true"
put_persistent "plugins.anomaly_detection.enabled"      "true"
put_persistent "plugins.index_management.enabled"       "true"
put_persistent "plugins.notifications.enabled"          "true"
put_persistent "plugins.security_analytics.enabled"     "true"
put_persistent "plugins.observability.enabled"          "true"
put_persistent "plugins.query.workbench.enabled"        "true"
put_persistent "plugins.ml_commons.enabled"             "true"
put_persistent "plugins.ml_commons.agent_framework.enabled" "true"
put_persistent "plugins.ml_commons.rag_pipeline_feature_enabled" "true"
put_persistent "plugins.knn.enabled"                    "true"

echo "==> Verificando que os plugins estao ativos"
for plugin in alerting anomaly_detection index_management notifications \
              security_analytics observability ml_commons knn; do
  val=$(api "${OS_URL}/_cluster/settings?include_defaults=false&filter_path=persistent.plugins.${plugin}.enabled" \
        | grep -o '"true"\|"false"' | head -1)
  printf "  %-25s = %s\n" "${plugin}" "${val:-n/a}"
done

echo "==> Catálogo de plugins instalados no nó"
api "${OS_URL}/_cat/plugins?v&s=component" | head -20

echo "OK: features oficiais ativadas."