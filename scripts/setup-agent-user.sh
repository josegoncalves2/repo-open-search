#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cria o usuario/role de ingestao usados pelos agentes (Fluent Bit).
# O agente NAO usa a conta admin: usa uma conta com permissao apenas de
# escrever/criar indices no padrao logs-*.
# ---------------------------------------------------------------------------
set -euo pipefail

. "$(dirname "$0")/lib.sh"

OS_URL="${OS_URL:-https://localhost:9200}"
OS_ADMIN_USER="${OS_ADMIN_USER:-admin}"
OS_ADMIN_PASS="${OS_ADMIN_PASS:?defina OS_ADMIN_PASS}"
AGENT_USER="${AGENT_USER:-agent-ingest}"
AGENT_PASS="${AGENT_PASS:?defina AGENT_PASS}"

api() { curl -sk -u "${OS_ADMIN_USER}:${OS_ADMIN_PASS}" -H 'Content-Type: application/json' "$@"; }

echo "==> criando role 'agent-ingest-role'"
api -XPUT "${OS_URL}/_plugins/_security/api/roles/agent-ingest-role" -d '{
  "cluster_permissions": [
    "cluster_composite_ops",
    "cluster_monitor",
    "indices:data/write/bulk"
  ],
  "index_permissions": [{
    "index_patterns": ["logs-*"],
    "allowed_actions": [
      "crud",
      "create_index",
      "indices:admin/mapping/put",
      "indices:admin/mapping/auto_put"
    ]
  }]
}' | head -c 300; echo

# Senha via hash bcrypt: nao passa pelo validador zxcvbn da Security REST API,
# entao AGENT_PASS pode ser qualquer coisa sem quebrar o provisionamento.
echo "==> criando usuario interno '${AGENT_USER}'"
put_internal_user "$OS_URL" "${OS_ADMIN_USER}:${OS_ADMIN_PASS}" "$AGENT_USER" "$AGENT_PASS" \
  '"backend_roles":[],"attributes":{"purpose":"log ingestion agent"}' | head -c 300; echo

echo "==> mapeando usuario -> role"
api -XPUT "${OS_URL}/_plugins/_security/api/rolesmapping/agent-ingest-role" -d "{
  \"users\": [\"${AGENT_USER}\"]
}" | head -c 300; echo

echo "==> validando credencial do agente"
code=$(curl -sk -o /dev/null -w '%{http_code}' -u "${AGENT_USER}:${AGENT_PASS}" "${OS_URL}/_cluster/health")
[ "$code" = "200" ] && echo "OK: ${AGENT_USER} autentica (HTTP $code)" || { echo "FALHA: HTTP $code"; exit 1; }
