#!/usr/bin/env bash
# ===========================================================================
#  Provisionamento da stack OpenSearch + Dashboards (single-node, seguranca ON)
#
#    curl -fsSL https://raw.githubusercontent.com/josegoncalves2/repo-open-search/main/install.sh | bash
#
#  Desinstalar (mantem os volumes):   ./install.sh --uninstall
#  Desinstalar + apagar dados:        ./install.sh --purge
#
#  O script BAIXA O REPOSITORIO inteiro para $STACK_DIR e usa o
#  docker-compose.yml de verdade (com o servico 'provisioner', que cria o
#  superusuario, ativa as features e provisiona IA/Agentic/LLM).
#  Nada de compose embutido: uma fonte da verdade so.
# ===========================================================================
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/opensearch}"
REPO_SLUG="${REPO_SLUG:-josegoncalves2/repo-open-search}"
REPO_REF="${REPO_REF:-main}"

# Senhas / credenciais (sobrescreva via variaveis de ambiente antes de rodar)
INITIAL_ADMIN_PASS="${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-P@ssw0rd2026!Key123}"
ADMIN_USER="${OPENSEARCH_ADMIN_USER:-pmotiadm}"
ADMIN_PASS="${OPENSEARCH_ADMIN_PASSWORD:-pmotiadm}"
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
log "1/5  Verificando pre-requisitos do host"

if ! command -v docker >/dev/null 2>&1; then
  log "Docker nao encontrado - instalando via get.docker.com"
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO systemctl enable --now docker
fi
$SUDO docker compose version >/dev/null 2>&1 || die "Docker Compose v2 nao disponivel."
command -v curl >/dev/null 2>&1 || die "curl e obrigatorio."
command -v tar  >/dev/null 2>&1 || die "tar e obrigatorio."

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

RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
[ "$RAM_GB" -ge 4 ] || warn "Host com ${RAM_GB}GB de RAM. Recomendado: 4GB+."

# =========================== 2. BAIXAR O REPOSITORIO ========================
log "2/5  Baixando ${REPO_SLUG}@${REPO_REF} para ${STACK_DIR}"
$SUDO mkdir -p "$STACK_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REPO_REF}" \
  | tar -xz -C "$TMP" --strip-components=1 \
  || die "falha ao baixar o repositorio (${REPO_SLUG}@${REPO_REF})"

# Preserva o .env existente: senhas ja aplicadas no indice de seguranca nao
# podem ser trocadas so reescrevendo o arquivo.
if [ -f "$STACK_DIR/.env" ]; then
  log "  .env existente preservado"
  $SUDO cp "$STACK_DIR/.env" "$TMP/.env"
fi
$SUDO cp -a "$TMP/." "$STACK_DIR/"
$SUDO chmod +x "$STACK_DIR"/scripts/*.sh "$STACK_DIR"/install.sh "$STACK_DIR"/agent/*.sh 2>/dev/null || true

# =========================== 3. .env ========================================
if [ ! -f "$STACK_DIR/.env" ]; then
  log "3/5  Gerando .env"
  $SUDO tee "$STACK_DIR/.env" >/dev/null <<ENV
OPENSEARCH_VERSION=${OPENSEARCH_VERSION:-3.8.0}
CLUSTER_NAME=opensearch-cluster
NODE_NAME=opensearch-node1

# Senha de BOOTSTRAP do usuario 'admin' (precisa passar no zxcvbn).
OPENSEARCH_INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASS}

# Superusuario EFETIVO, criado pelo provisioner com all_access.
OPENSEARCH_ADMIN_USER=${ADMIN_USER}
OPENSEARCH_ADMIN_PASSWORD=${ADMIN_PASS}

OPENSEARCH_JAVA_OPTS=-Xms1536m -Xmx1536m
OPENSEARCH_MEM_LIMIT=3g
DASHBOARDS_MEM_LIMIT=1g

OPENSEARCH_PORT=9200
OPENSEARCH_PERF_PORT=9600
DASHBOARDS_PORT=5601
ENROLL_PORT=80

LLM_PROVIDER=${LLM_PROVIDER:-openrouter}
LLM_ENDPOINT=${LLM_ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}
LLM_MODEL=${LLM_MODEL:-minimax/minimax-m3:free}
LLM_API_KEY=${LLM_API_KEY:-coloque-sua-chave-openrouter-aqui}

EMBEDDING_MODEL=${EMBEDDING_MODEL:-huggingface/sentence-transformers/all-MiniLM-L6-v2}
EMBEDDING_VERSION=${EMBEDDING_VERSION:-1.0.2}

AGENT_USER=${AGENT_USER}
AGENT_PASS=${AGENT_PASS}
ENV
  $SUDO chmod 600 "$STACK_DIR/.env"
else
  log "3/5  .env ja existe - mantido como esta"
fi

# =========================== 4. SUBIR A STACK ===============================
# O servico 'provisioner' do compose cria o superusuario, ativa as features
# (setup-features.sh), cria o usuario de ingestao e provisiona IA (setup-ai.sh).
# O Dashboards so sobe depois que ele termina com sucesso.
log "4/5  Subindo os containers (o provisioner faz features + IA)"
(cd "$STACK_DIR" && $SUDO docker compose up -d) || {
  warn "Falha no 'compose up'. Log do provisioner:"
  (cd "$STACK_DIR" && $SUDO docker compose logs --tail 40 provisioner) || true
  die "provisionamento falhou"
}

# =========================== 5. VALIDACAO FINAL =============================
log "5/5  Validando a stack"
wait_health() {
  local name="$1" i st
  for i in $(seq 1 90); do
    st=$($SUDO docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)
    [ "$st" = healthy ] && { log "$name: healthy"; return 0; }
    sleep 5
  done
  warn "Timeout aguardando $name (siga com 'docker compose logs $name')"
}
wait_health opensearch-node
wait_health opensearch-dashboards

curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" https://localhost:9200 | grep -q '"number"' \
  && log "API responde com o superusuario '${ADMIN_USER}'" \
  || warn "API nao respondeu com '${ADMIN_USER}' - veja 'docker compose logs provisioner'"
[ "$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:9200)" = 401 ] \
  && log "Acesso anonimo bloqueado (401) - seguranca ativa" \
  || warn "Acesso anonimo NAO retornou 401"

IP=$(hostname -I | awk '{print $1}')
cat <<FIM

===========================================================================
 Stack OpenSearch provisionada
---------------------------------------------------------------------------
 Dashboards   : http://${IP}:5601        (${ADMIN_USER} / ${ADMIN_PASS})
 API          : https://${IP}:9200       (TLS autoassinado, use curl -k)
 Diretorio    : ${STACK_DIR}

 Enroll de agentes:
   Linux   : curl -fsSL http://${IP}/install-agent.sh | sudo sh
   Windows : irm http://${IP}/install-agent.ps1 | iex

 Operacao:
   cd ${STACK_DIR} && docker compose ps
   cd ${STACK_DIR} && docker compose logs -f provisioner
   ${STACK_DIR}/install.sh --uninstall     # para a stack, mantem dados
   ${STACK_DIR}/install.sh --purge         # para a stack e APAGA os dados
===========================================================================
FIM
