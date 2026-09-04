#!/usr/bin/env sh
# ===========================================================================
#  Enroll de agente de logs -> OpenSearch  (Linux)
#
#  Instalar:
#    curl -fsSL http://192.168.1.73/install-agent.sh | sudo sh
#
#  Desinstalar:
#    curl -fsSL http://192.168.1.73/install-agent.sh | sudo sh -s -- --uninstall
#
#  Agente: Fluent Bit (pacote oficial fluent/fluent-bit)
#  Destino: indice logs-<hostname> no OpenSearch
# ===========================================================================
set -eu

# --------------------------- parametros (override por env) -----------------
OS_HOST="${OS_HOST:-192.168.1.73}"
OS_PORT="${OS_PORT:-9200}"
OS_USER="${OS_USER:-agent-ingest}"
OS_PASS="${OS_PASS:-Ag3nt!Ingest2026#LogSecure}"
OS_TLS="${OS_TLS:-On}"
OS_TLS_VERIFY="${OS_TLS_VERIFY:-Off}"   # Off por causa do cert autoassinado (demo)
INDEX_PREFIX="${INDEX_PREFIX:-logs}"

CONF_DIR=/etc/fluent-bit
CONF_FILE="$CONF_DIR/fluent-bit.conf"
SVC=fluent-bit

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Execute como root (use sudo)."

# --------------------------- deteccao de distro ----------------------------
if [ -r /etc/os-release ]; then . /etc/os-release; else die "/etc/os-release ausente."; fi
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) PKG=apt ;;
  *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) PKG=$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum) ;;
  *) die "Distribuicao nao suportada: ${ID:-desconhecida}" ;;
esac

# =========================== DESINSTALACAO =================================
uninstall() {
  log "Parando e desabilitando $SVC"
  systemctl stop  "$SVC" 2>/dev/null || true
  systemctl disable "$SVC" 2>/dev/null || true

  log "Removendo pacote fluent-bit"
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y fluent-bit >/dev/null 2>&1 || true
         rm -f /etc/apt/sources.list.d/fluent-bit.list /usr/share/keyrings/fluentbit-keyring.gpg ;;
    *)   "$PKG" remove -y fluent-bit >/dev/null 2>&1 || true
         rm -f /etc/yum.repos.d/fluent-bit.repo ;;
  esac

  log "Removendo configuracao e estado"
  rm -rf "$CONF_DIR" /var/log/fluent-bit /var/lib/fluent-bit
  systemctl daemon-reload 2>/dev/null || true
  log "Agente removido deste host ($(hostname))."
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

# =========================== INSTALACAO ====================================
log "Host: $(hostname)  |  Distro: ${PRETTY_NAME:-$ID}  |  Destino: $OS_HOST:$OS_PORT"

install_pkg() {
  if command -v fluent-bit >/dev/null 2>&1 || [ -x /opt/fluent-bit/bin/fluent-bit ]; then
    log "Fluent Bit ja instalado - seguindo para configuracao"; return
  fi
  case "$PKG" in
    apt)
      log "Configurando repositorio APT oficial do Fluent Bit"
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg ca-certificates >/dev/null
      install -d -m 0755 /usr/share/keyrings
      curl -fsSL https://packages.fluentbit.io/fluentbit.key \
        | gpg --dearmor -o /usr/share/keyrings/fluentbit-keyring.gpg
      CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo jammy)}"
      echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/${ID} ${CODENAME} main" \
        > /etc/apt/sources.list.d/fluent-bit.list
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fluent-bit >/dev/null
      ;;
    *)
      log "Configurando repositorio YUM/DNF oficial do Fluent Bit"
      cat > /etc/yum.repos.d/fluent-bit.repo <<'REPO'
[fluent-bit]
name = Fluent Bit
baseurl = https://packages.fluentbit.io/centos/$releasever/$basearch/
gpgcheck=1
gpgkey=https://packages.fluentbit.io/fluentbit.key
repo_gpgcheck=1
enabled=1
REPO
      "$PKG" install -y fluent-bit >/dev/null
      ;;
  esac
  log "Fluent Bit instalado"
}
install_pkg

# --------------------------- configuracao ----------------------------------
log "Gerando $CONF_FILE"
mkdir -p "$CONF_DIR" /var/lib/fluent-bit
HOSTN=$(hostname | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')

# Escolhe as fontes de log que realmente existem neste host
SYSLOG_PATH=/var/log/syslog;  [ -r /var/log/syslog ]   || SYSLOG_PATH=/var/log/messages
AUTH_PATH=/var/log/auth.log;  [ -r /var/log/auth.log ] || AUTH_PATH=/var/log/secure

cat > "$CONF_FILE" <<CONF
[SERVICE]
    Flush         5
    Daemon        Off
    Log_Level     info
    Parsers_File  parsers.conf
    HTTP_Server   On
    HTTP_Listen   127.0.0.1
    HTTP_Port     2020
    storage.path  /var/lib/fluent-bit/
    storage.sync  normal

# ------------------------------- ENTRADAS ---------------------------------
[INPUT]
    Name              tail
    Tag               host.syslog
    Path              ${SYSLOG_PATH}
    DB                /var/lib/fluent-bit/syslog.db
    Refresh_Interval  10
    Skip_Long_Lines   On

[INPUT]
    Name              tail
    Tag               host.auth
    Path              ${AUTH_PATH}
    DB                /var/lib/fluent-bit/auth.db
    Refresh_Interval  10
    Skip_Long_Lines   On

[INPUT]
    Name          systemd
    Tag           host.journal
    DB            /var/lib/fluent-bit/journal.db
    Read_From_Tail On

# Metricas basicas do host (CPU / memoria / disco)
[INPUT]
    Name          cpu
    Tag           host.metrics.cpu
    Interval_Sec  30

[INPUT]
    Name          mem
    Tag           host.metrics.mem
    Interval_Sec  30

# ------------------------------- FILTROS ----------------------------------
[FILTER]
    Name          record_modifier
    Match         *
    Record        agent_hostname ${HOSTN}
    Record        agent_type     fluent-bit
    Record        agent_os       linux

# ------------------------------- SAIDA ------------------------------------
[OUTPUT]
    Name                opensearch
    Match               *
    Host                ${OS_HOST}
    Port                ${OS_PORT}
    HTTP_User           ${OS_USER}
    HTTP_Passwd         ${OS_PASS}
    tls                 ${OS_TLS}
    tls.verify          ${OS_TLS_VERIFY}
    Index               ${INDEX_PREFIX}-${HOSTN}
    Suppress_Type_Name  On
    Logstash_Format     Off
    Trace_Error         On
    Retry_Limit         5
    storage.total_limit_size 200M
CONF
chmod 600 "$CONF_FILE"

# --------------------------- teste de conectividade -------------------------
log "Testando conectividade com o OpenSearch"
SCHEME=https; [ "$OS_TLS" = "Off" ] && SCHEME=http
code=$(curl -sk -o /dev/null -w '%{http_code}' -u "${OS_USER}:${OS_PASS}" \
       "${SCHEME}://${OS_HOST}:${OS_PORT}/_cluster/health" || echo 000)
case "$code" in
  200) log "Conectividade e credenciais OK (HTTP 200)" ;;
  401|403) die "Credenciais recusadas (HTTP $code). Verifique OS_USER/OS_PASS." ;;
  000) die "Sem rota ate ${OS_HOST}:${OS_PORT}. Verifique rede/firewall." ;;
  *)   warn "Resposta inesperada do OpenSearch: HTTP $code (seguindo mesmo assim)" ;;
esac

# --------------------------- servico ---------------------------------------
log "Habilitando e iniciando o servico $SVC"
systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1 || true
systemctl restart "$SVC"
sleep 3
if systemctl is-active --quiet "$SVC"; then
  log "Servico ativo."
else
  warn "Servico nao subiu. Ultimas linhas do journal:"
  journalctl -u "$SVC" -n 20 --no-pager || true
  exit 1
fi

cat <<FIM

===========================================================================
 Agente instalado com sucesso
---------------------------------------------------------------------------
 Host             : ${HOSTN}
 Indice destino   : ${INDEX_PREFIX}-${HOSTN}
 OpenSearch       : ${SCHEME}://${OS_HOST}:${OS_PORT}
 Config           : ${CONF_FILE}

 Verificar status : systemctl status ${SVC}
 Ver logs         : journalctl -u ${SVC} -f
 Conferir ingestao:
   curl -sk -u '${OS_USER}:***' \\
     "${SCHEME}://${OS_HOST}:${OS_PORT}/${INDEX_PREFIX}-${HOSTN}/_count?pretty"

 Desinstalar:
   curl -fsSL http://${OS_HOST}/install-agent.sh | sudo sh -s -- --uninstall
===========================================================================
FIM
