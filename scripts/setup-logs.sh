#!/usr/bin/env bash
# ===========================================================================
# setup-logs.sh - o equivalente ao "filebeat setup" do lado do OpenSearch:
#   1. politica ISM (rollover + retencao) para os indices dos agentes
#   2. index template de 'logs-*' com mapping correto e 0 replicas
#
# Sem o template, o OpenSearch adivinha o mapping por dynamic mapping: campos
# como agent_hostname viram 'text' e nao dao para agregar (as visualizacoes de
# "hosts reportando" ficariam vazias) e @timestamp pode nem virar 'date'.
# Idempotente.
# ===========================================================================
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9200}"
OS_ADMIN_USER="${OS_ADMIN_USER:-admin}"
OS_ADMIN_PASS="${OS_ADMIN_PASS:?defina OS_ADMIN_PASS}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_ROLLOVER_SIZE="${LOG_ROLLOVER_SIZE:-5gb}"
LOG_ROLLOVER_AGE="${LOG_ROLLOVER_AGE:-7d}"

api() { curl -sk -u "${OS_ADMIN_USER}:${OS_ADMIN_PASS}" -H 'Content-Type: application/json' "$@"; }

echo "==> Politica ISM 'logs-policy' (rollover ${LOG_ROLLOVER_SIZE}/${LOG_ROLLOVER_AGE}, retencao ${LOG_RETENTION_DAYS}d)"
api -XPUT "${OS_URL}/_plugins/_ism/policies/logs-policy" -d "{
  \"policy\": {
    \"description\": \"Rollover e retencao dos indices de log dos agentes\",
    \"default_state\": \"hot\",
    \"ism_template\": [{ \"index_patterns\": [\"logs-*\"], \"priority\": 100 }],
    \"states\": [
      { \"name\": \"hot\",
        \"actions\": [{ \"rollover\": { \"min_primary_shard_size\": \"${LOG_ROLLOVER_SIZE}\", \"min_index_age\": \"${LOG_ROLLOVER_AGE}\" } }],
        \"transitions\": [{ \"state_name\": \"delete\", \"conditions\": { \"min_index_age\": \"${LOG_RETENTION_DAYS}d\" } }] },
      { \"name\": \"delete\",
        \"actions\": [{ \"delete\": {} }],
        \"transitions\": [] }
    ]
  }
}" | head -c 200; echo

echo "==> Index template 'logs-agents'"
api -XPUT "${OS_URL}/_index_template/logs-agents" -d '{
  "index_patterns": ["logs-*"],
  "priority": 200,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "refresh_interval": "5s"
    },
    "mappings": {
      "properties": {
        "@timestamp":     { "type": "date" },
        "agent_hostname": { "type": "keyword" },
        "agent_type":     { "type": "keyword" },
        "agent_os":       { "type": "keyword" },
        "log":            { "type": "text" },
        "MESSAGE":        { "type": "text" },
        "PRIORITY":       { "type": "keyword" },
        "SYSLOG_IDENTIFIER": { "type": "keyword" },
        "_SYSTEMD_UNIT":  { "type": "keyword" },
        "_HOSTNAME":      { "type": "keyword" },
        "_TRANSPORT":     { "type": "keyword" },
        "cpu_p":          { "type": "float" },
        "system_p":       { "type": "float" },
        "user_p":         { "type": "float" },
        "Mem.total":      { "type": "long" },
        "Mem.used":       { "type": "long" },
        "Mem.free":       { "type": "long" },
        "Swap.total":     { "type": "long" },
        "Swap.used":      { "type": "long" },
        "Swap.free":      { "type": "long" }
      }
    }
  }
}' | head -c 200; echo

echo "OK: template e politica de retencao aplicados."
