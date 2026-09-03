#!/usr/bin/env bash
# ===========================================================================
#  Provisionamento da stack OpenSearch + Dashboards (single-node, seguranca ON)
#
#    curl -fsSL https://raw.githubusercontent.com/josegoncalves2/repo-open-search/main/install.sh | bash
#
#  Desinstalar (mantem os volumes):   ./install.sh --uninstall
#  Desinstalar + apagar dados:        ./install.sh --purge
# ===========================================================================
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/opensearch}"
OPENSEARCH_VERSION="${OPENSEARCH_VERSION:-3.8.0}"
ADMIN_PASS="${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-P@ssw0rd2026!Key123}"
AGENT_USER="${AGENT_USER:-agent-ingest}"
AGENT_PASS="${AGENT_PASS:-Ag3nt!Ingest2026#Log}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

# =========================== DESINSTALACAO =================================
case "${1:-}" in
  --uninstall) log "Derrubando a stack (volumes preservados)"
               (cd "$STACK_DIR" && $SUDO docker compose down); exit 0 ;;
  --purge)     warn "Derrubando a stack e APAGANDO todos os dados"
               (cd "$STACK_DIR" && $SUDO docker compose down -v); exit 0 ;;
esac

# =========================== 1. PRE-REQUISITOS ==============================
log "1/6  Verificando pre-requisitos do host"

if ! command -v docker >/dev/null 2>&1; then
  log "Docker nao encontrado - instalando via get.docker.com"
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO systemctl enable --now docker
fi
$SUDO docker compose version >/dev/null 2>&1 || die "Docker Compose v2 nao disponivel."

# vm.max_map_count: exigido pelo Lucene. Aplica agora + torna persistente.
CURRENT=$(sysctl -n vm.max_map_count)
if [ "$CURRENT" -lt 262144 ]; then
  log "Ajustando vm.max_map_count ($CURRENT -> 262144)"
  $SUDO sysctl -w vm.max_map_count=262144 >/dev/null
  echo 'vm.max_map_count=262144' | $SUDO tee /etc/sysctl.d/99-opensearch.conf >/dev/null
  $SUDO sysctl --system >/dev/null
else
  log "vm.max_map_count ja adequado ($CURRENT >= 262144)"
fi

# Aviso de RAM: OpenSearch + Dashboards pedem ~4 GB confortaveis
RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
[ "$RAM_GB" -ge 4 ] || warn "Host com ${RAM_GB}GB de RAM. Recomendado: 4GB+."

# =========================== 2. ARQUIVOS ====================================
log "2/6  Escrevendo arquivos em $STACK_DIR"
$SUDO mkdir -p "$STACK_DIR/agent"

$SUDO tee "$STACK_DIR/.env" >/dev/null <<ENV
OPENSEARCH_VERSION=${OPENSEARCH_VERSION}
CLUSTER_NAME=opensearch-cluster
NODE_NAME=opensearch-node1
OPENSEARCH_INITIAL_ADMIN_PASSWORD=${ADMIN_PASS}
OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m"
OPENSEARCH_MEM_LIMIT=2g
DASHBOARDS_MEM_LIMIT=1g
OPENSEARCH_PORT=9200
OPENSEARCH_PERF_PORT=9600
DASHBOARDS_PORT=5601
ENROLL_PORT=80
ENV
$SUDO chmod 600 "$STACK_DIR/.env"

$SUDO tee "$STACK_DIR/docker-compose.yml" >/dev/null <<'YAML'
services:
  opensearch:
    image: opensearchproject/opensearch:${OPENSEARCH_VERSION}
    container_name: opensearch-node
    environment:
      - cluster.name=${CLUSTER_NAME}
      - node.name=${NODE_NAME}
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - OPENSEARCH_JAVA_OPTS=${OPENSEARCH_JAVA_OPTS}
      - OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_INITIAL_ADMIN_PASSWORD}
      - DISABLE_SECURITY_PLUGIN=false
      - DISABLE_INSTALL_DEMO_CONFIG=false
    ulimits:
      memlock: { soft: -1, hard: -1 }
      nofile:  { soft: 65536, hard: 65536 }
    volumes:
      - opensearch-data:/usr/share/opensearch/data
    ports:
      - "${OPENSEARCH_PORT}:9200"
      - "${OPENSEARCH_PERF_PORT}:9600"
    networks: [opensearch-net]
    deploy:
      resources:
        limits: { memory: "${OPENSEARCH_MEM_LIMIT}" }
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          curl -sk -u "admin:$${OPENSEARCH_INITIAL_ADMIN_PASSWORD}"
          https://localhost:9200/_cluster/health
          | grep -qE '"status":"(green|yellow)"'
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 60s
    restart: unless-stopped

  opensearch-dashboards:
    image: opensearchproject/opensearch-dashboards:${OPENSEARCH_VERSION}
    container_name: opensearch-dashboards
    environment:
      - OPENSEARCH_HOSTS=["https://opensearch:9200"]
      - OPENSEARCH_USERNAME=admin
      - OPENSEARCH_PASSWORD=${OPENSEARCH_INITIAL_ADMIN_PASSWORD}
      - OPENSEARCH_SSL_VERIFICATIONMODE=none
      - SERVER_HOST=0.0.0.0
      - SERVER_PORT=5601
    volumes:
      - opensearch-dashboards-data:/usr/share/opensearch-dashboards/data
    ports:
      - "${DASHBOARDS_PORT}:5601"
    networks: [opensearch-net]
    depends_on:
      opensearch: { condition: service_healthy }
    deploy:
      resources:
        limits: { memory: "${DASHBOARDS_MEM_LIMIT}" }
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          curl -sf -u "admin:$${OPENSEARCH_PASSWORD}"
          http://localhost:5601/api/status
          | grep -q '"state":"green"'
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 60s
    restart: unless-stopped

  enroll:
    image: nginx:1.29-alpine
    container_name: opensearch-enroll
    volumes:
      - ./agent:/usr/share/nginx/html:ro
    ports:
      - "${ENROLL_PORT}:80"
    networks: [opensearch-net]
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/install-agent.sh >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s
    restart: unless-stopped

volumes:
  opensearch-data:            { driver: local }
  opensearch-dashboards-data: { driver: local }

networks:
  opensearch-net: { driver: bridge }
YAML

# =========================== 3. SUBIR A STACK ===============================
log "3/6  Subindo os containers"
(cd "$STACK_DIR" && $SUDO docker compose up -d)

# =========================== 4. AGUARDAR SAUDE ==============================
log "4/6  Aguardando OpenSearch e Dashboards ficarem healthy"
wait_health() {
  local name="$1" i st
  for i in $(seq 1 60); do
    st=$($SUDO docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)
    [ "$st" = healthy ] && { log "$name: healthy"; return 0; }
    [ "$st" = unhealthy ] && { $SUDO docker logs --tail 30 "$name"; die "$name ficou unhealthy"; }
    sleep 5
  done
  die "Timeout aguardando $name"
}
wait_health opensearch-node
wait_health opensearch-dashboards

# =========================== 5. USUARIO DE INGESTAO + FEATURES + AI =======
log "5/7  Criando usuario de ingestao '${AGENT_USER}' (permissao só em logs-*)"
api() { curl -sk -u "admin:${ADMIN_PASS}" -H 'Content-Type: application/json' "$@"; }
api -XPUT "https://localhost:9200/_plugins/_security/api/roles/agent-ingest-role" -d '{
  "cluster_permissions":["cluster_composite_ops","cluster_monitor","indices:data/write/bulk"],
  "index_permissions":[{"index_patterns":["logs-*"],
    "allowed_actions":["crud","create_index","indices:admin/mapping/put","indices:admin/mapping/auto_put"]}]
}' >/dev/null
api -XPUT "https://localhost:9200/_plugins/_security/api/internalusers/${AGENT_USER}" \
    -d "{\"password\":\"${AGENT_PASS}\"}" >/dev/null
api -XPUT "https://localhost:9200/_plugins/_security/api/rolesmapping/agent-ingest-role" \
    -d "{\"users\":[\"${AGENT_USER}\"]}" >/dev/null
code=$(curl -sk -o /dev/null -w '%{http_code}' -u "${AGENT_USER}:${AGENT_PASS}" https://localhost:9200/_cluster/health)
[ "$code" = 200 ] && log "usuario ${AGENT_USER} valida (HTTP 200)" || warn "usuario de ingestao respondeu HTTP $code"

# Ativa TODOS os plugins oficiais (alerting, anomaly, ml_commons, ISM, etc.)
log "5b/7  Ativando plugins oficiais (alerting, anomaly, ML Commons, ISM, observability)"
( cd "$STACK_DIR" && $SUDO OS_ADMIN_PASS="${ADMIN_PASS}" AGENT_USER="${AGENT_USER}" \
    AGENT_PASS="${AGENT_PASS}" bash scripts/setup-features.sh ) || warn "Falha ativando plugins (seguindo)."

# Provisiona o stack de IA (root agent OpenRouter + embeddings + tools)
if [ -n "${LLM_API_KEY:-}" ]; then
  log "5c/7  Provisionando IA / Agentic / LLM (connector OpenRouter + root agent)"
  ( cd "$STACK_DIR" && $SUDO bash -c "
    set -a; . ./.env; set +a
    OS_ADMIN_PASS='${ADMIN_PASS}' \
    bash scripts/setup-ai.sh
  " ) || warn "Falha no setup de IA (verifique LLM_API_KEY). Pode reexecutar depois."
else
  warn "LLM_API_KEY nao definido - pulei setup de IA. Defina no .env e rode scripts/setup-ai.sh depois."
fi

# =========================== 7. VALIDACAO FINAL =============================
log "7/7  Validando a stack"
curl -sk -u "admin:${ADMIN_PASS}" https://localhost:9200 | grep -q '"number"' \
  && log "API OpenSearch responde com autenticacao" || die "API nao respondeu"
curl -sk -o /dev/null -w '%{http_code}' https://localhost:9200 | grep -q 401 \
  && log "Acesso anonimo bloqueado (401) - seguranca ativa" || warn "Acesso anonimo NAO retornou 401"

IP=$(hostname -I | awk '{print $1}')
cat <<FIM

===========================================================================
 Stack OpenSearch ${OPENSEARCH_VERSION} provisionada
---------------------------------------------------------------------------
 Dashboards   : http://${IP}:5601        (admin / ${ADMIN_PASS})
 API          : https://${IP}:9200       (TLS autoassinado, use curl -k)
 Diretorio    : ${STACK_DIR}

 Enroll de agentes:
   Linux   : curl -fsSL http://${IP}/install-agent.sh | sudo sh
   Windows : irm http://${IP}/install-agent.ps1 | iex

 Operacao:
   docker compose -f ${STACK_DIR}/docker-compose.yml ps
   docker compose -f ${STACK_DIR}/docker-compose.yml logs -f
   ${STACK_DIR}/install.sh --uninstall     # para a stack, mantem dados
   ${STACK_DIR}/install.sh --purge         # para a stack e APAGA os dados
===========================================================================
FIM
