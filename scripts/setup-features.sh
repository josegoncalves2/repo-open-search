#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-features.sh
#
# Os plugins oficiais (alerting, anomaly detection, ISM, observability,
# notifications, security analytics, query workbench, ml-commons, k-NN) ja
# vem ATIVOS na imagem; os node settings ficam no docker-compose.yml (nao ha
# config/opensearch.yml de proposito - ver README).
#
# Este script cuida do que precisa ser dinamico (cluster settings) e valida
# que tudo esta no ar. Idempotente.
# ---------------------------------------------------------------------------
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9200}"
OS_ADMIN_USER="${OS_ADMIN_USER:-admin}"
OS_ADMIN_PASS="${OS_ADMIN_PASS:?defina OS_ADMIN_PASS}"

api() {
  curl -sk -u "${OS_ADMIN_USER}:${OS_ADMIN_PASS}" \
       -H 'Content-Type: application/json' "$@"
}

echo "==> Ativando features dinamicas (cluster settings persistentes)"
api -XPUT "${OS_URL}/_cluster/settings" -d '{
  "persistent": {
    "plugins.ml_commons.only_run_on_ml_node": false,
    "plugins.ml_commons.model_access_control_enabled": false,
    "plugins.ml_commons.connector_access_control_enabled": false,
    "plugins.ml_commons.memory_feature_enabled": true,
    "plugins.ml_commons.rag_pipeline_feature_enabled": true,
    "plugins.ml_commons.agent_framework_enabled": true,
    "plugins.ml_commons.allow_registering_model_via_url": true,
    "plugins.ml_commons.allow_registering_model_via_local_file": true,
    "plugins.ml_commons.native_memory_threshold": 100,
    "plugins.ml_commons.jvm_heap_memory_threshold": 100,
    "plugins.ml_commons.disk_free_space_threshold": -1,
    "plugins.anomaly_detection.enabled": true,
    "plugins.index_state_management.enabled": true,
    "plugins.security_analytics.enable_detectors": true
  }
}' | head -c 400; echo

echo
echo "==> Plugins instalados no no"
api "${OS_URL}/_cat/plugins?v&s=component" | sed 's/^opensearch-node1 //'

echo
echo "==> Cluster settings de ML ativos"
api "${OS_URL}/_cluster/settings?include_defaults=true&filter_path=**.ml_commons.agent_framework_enabled,**.ml_commons.rag_pipeline_feature_enabled,**.ml_commons.memory_feature_enabled"
echo

echo "==> Health do cluster"
api "${OS_URL}/_cluster/health?pretty" | grep -E '"status"|"number_of_nodes"'

echo "OK: features verificadas."
