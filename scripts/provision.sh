#!/usr/bin/env bash
# ===========================================================================
# provision.sh - roda UMA vez (container 'provisioner') depois que o OpenSearch
# fica healthy. Idempotente: pode rodar de novo sem quebrar nada.
#
#   1. Espera a camada de seguranca responder
#   2. Autentica como 'admin' (senha de bootstrap - o user 'admin' e RESERVADO
#      no OpenSearch 3.x e a senha dele NAO pode ser trocada via API)
#   3. Cria o superusuario final <OPENSEARCH_ADMIN_USER>/<OPENSEARCH_ADMIN_PASSWORD>
#      mapeado em all_access + security_rest_api_access  (ex.: pmotiadm/pmotiadm)
#      A senha e aplicada como HASH bcrypt - ver comentario em lib.sh sobre o
#      validador zxcvbn ("Weak password").
#   4. setup-features.sh   - features dinamicas + verificacao
#   5. setup-agent-user.sh - usuario de ingestao (logs-*)
#   6. setup-ai.sh         - connector + modelos + root agent (IA/Agentic/LLM)
# ===========================================================================
set -euo pipefail

. "$(dirname "$0")/lib.sh"

OS_URL="${OS_URL:-https://opensearch:9200}"
BOOT_USER="admin"
BOOT_PASS="${OPENSEARCH_INITIAL_ADMIN_PASSWORD:?defina OPENSEARCH_INITIAL_ADMIN_PASSWORD}"
ADMIN_USER="${OPENSEARCH_ADMIN_USER:-pmotiadm}"
ADMIN_PASS="${OPENSEARCH_ADMIN_PASSWORD:?defina OPENSEARCH_ADMIN_PASSWORD}"

log()  { printf '\033[1;32m[provision]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[provision]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[provision]\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------- 1. espera a seguranca -------------------------
# Sonda JA autenticada como 'admin' (bootstrap): uma sonda anonima deixaria
# "BackendRegistry: No 'Authorization' header" no log do no. 200 = seguranca
# no ar; 401/403 = no ar mas ainda inicializando o indice de seguranca.
log "Aguardando a camada de seguranca do OpenSearch em ${OS_URL}"
ok=""
for _ in $(seq 1 60); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' -u "${BOOT_USER}:${BOOT_PASS}" "${OS_URL}" || true)
  case "$code" in 200) ok=1; break ;; esac
  sleep 3
done
[ -n "$ok" ] || die "OpenSearch nao respondeu a tempo"

auth_ok() { curl -sk -u "$1:$2" "${OS_URL}/_cluster/health" | grep -q '"status"'; }

# --------------------------- 2. quem autentica? ----------------------------
if auth_ok "$ADMIN_USER" "$ADMIN_PASS"; then
  CU="$ADMIN_USER"; CP="$ADMIN_PASS"; log "superusuario '${ADMIN_USER}' ja existe"
elif auth_ok "$BOOT_USER" "$BOOT_PASS"; then
  CU="$BOOT_USER"; CP="$BOOT_PASS"; log "autenticado como admin (bootstrap)"
else
  die "Nenhuma credencial conhecida autentica. Se o volume tem um indice de \
seguranca antigo, rode 'docker compose down -v' e suba de novo."
fi

api() { curl -sk -u "${CU}:${CP}" -H 'Content-Type: application/json' "$@"; }

# --------------------------- 3. superusuario final -------------------------
# A senha vai como HASH bcrypt: o validador zxcvbn da Security REST API so
# inspeciona o campo "password", entao senhas curtas (ex.: 'pmotiadm') passam.
# Detalhes e alternativas descartadas: ver lib.sh.
if [ "$CU" != "$ADMIN_USER" ]; then
  log "Criando superusuario '${ADMIN_USER}' (senha via hash bcrypt)"
  r=$(put_internal_user "$OS_URL" "${CU}:${CP}" "$ADMIN_USER" "$ADMIN_PASS" \
        '"backend_roles":["admin"],"attributes":{"purpose":"superusuario final da stack"}')
  echo "$r" | grep -qiE "created|updated|OK" || die "falha ao criar superuser: $r"

  r=$(api -XPUT "${OS_URL}/_plugins/_security/api/rolesmapping/all_access" -d "{
    \"backend_roles\": [\"admin\"],
    \"users\": [\"${ADMIN_USER}\"]
  }")
  echo "$r" | grep -qiE "created|updated|OK" || warn "resposta ao mapear all_access: $r"

  r=$(api -XPUT "${OS_URL}/_plugins/_security/api/rolesmapping/security_rest_api_access" -d "{
    \"users\": [\"${ADMIN_USER}\"]
  }")
  echo "$r" | grep -qiE "created|updated|OK" || warn "resposta ao mapear security_rest_api_access: $r"

  for _ in $(seq 1 10); do auth_ok "$ADMIN_USER" "$ADMIN_PASS" && break; sleep 2; done
  auth_ok "$ADMIN_USER" "$ADMIN_PASS" \
    || die "superusuario '${ADMIN_USER}' nao autentica apos a criacao"
  CU="$ADMIN_USER"; CP="$ADMIN_PASS"
  log "superusuario '${ADMIN_USER}' pronto"
fi

export OS_URL OS_ADMIN_USER="$CU" OS_ADMIN_PASS="$CP"

# --------------------------- 4. features -----------------------------------
log "Ativando features (setup-features.sh)"
bash "$(dirname "$0")/setup-features.sh" || warn "setup-features.sh falhou (seguindo)"

# --------------------------- 5. usuario de ingestao ------------------------
if [ -n "${AGENT_USER:-}" ] && [ -n "${AGENT_PASS:-}" ]; then
  log "Criando usuario de ingestao '${AGENT_USER}' (setup-agent-user.sh)"
  AGENT_USER="$AGENT_USER" AGENT_PASS="$AGENT_PASS" \
    bash "$(dirname "$0")/setup-agent-user.sh" || warn "setup-agent-user.sh falhou (seguindo)"
fi

# --------------------------- 6. IA / Agentic / LLM -------------------------
if [ -n "${LLM_API_KEY:-}" ] && [ "${LLM_API_KEY}" != "coloque-sua-chave-openrouter-aqui" ]; then
  log "Provisionando IA / Agentic / LLM (setup-ai.sh)"
  bash "$(dirname "$0")/setup-ai.sh" || warn "setup-ai.sh falhou - reexecute depois"
else
  warn "LLM_API_KEY nao definido - pulei o setup de IA"
fi

log "Provisionamento concluido. Login: ${ADMIN_USER} / (senha em OPENSEARCH_ADMIN_PASSWORD)"
