#!/usr/bin/env sh
# ===========================================================================
#  Enroll de agente de logs -> OpenSearch  (Linux)
#
#  UM host (o proprio):
#    curl -fsSL http://192.168.1.73/install-agent.sh | sudo sh
#    curl -fsSL http://192.168.1.73/install-agent.sh | sudo sh -s -- --uninstall
#
#  VARIOS hosts (o mesmo script se distribui por SSH):
#    ./install-agent.sh --hosts hosts.txt
#    ./install-agent.sh --hosts hosts.txt --uninstall
#    ./install-agent.sh web1 web2 db1
#
#    hosts.txt: um por linha, [usuario@]host[:porta]; '#' comenta.
#    Chave SSH por padrao; --ask-pass usa senha (requer sshpass) e
#    --sudo-pass para sudo com senha. Em automacao, exporte SSH_PASSWORD
#    e SUDO_PASSWORD. Paralelismo com -j (padrao 10).
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

# ===========================================================================
# MODO FROTA: se vierem hosts, este mesmo script se distribui por SSH e cada
# alvo o executa em modo local. Nao precisa de root aqui - so nos alvos.
# ===========================================================================
HOSTS_FILE=$(mktemp); trap 'rm -f "$HOSTS_FILE"' EXIT
FLEET_JOBS="${JOBS:-10}"
FLEET_SERVER="${ENROLL_SERVER:-$OS_HOST}"
FLEET_USER="${SSH_USER:-${USER:-root}}"
FLEET_ASKPASS=0; FLEET_SSHPASS=""; FLEET_SUDOPASS=""
DO_UNINSTALL=0
ARGS_LEFT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hosts)     [ -r "${2:-}" ] || die "arquivo de hosts ilegivel: ${2:-}"
                 sed 's/#.*//' "$2" | tr -d '[:blank:]' | grep -v '^$' >> "$HOSTS_FILE"
                 shift 2 ;;
    --server)    FLEET_SERVER="$2"; shift 2 ;;
    -u|--user)   FLEET_USER="$2";   shift 2 ;;
    -j|--jobs)   FLEET_JOBS="$2";   shift 2 ;;
    --ask-pass)  FLEET_ASKPASS=1;   shift ;;
    --sudo-pass) if [ -n "${SUDO_PASSWORD:-}" ]; then FLEET_SUDOPASS="$SUDO_PASSWORD"
                 else printf 'senha do sudo remoto: ' >&2; stty -echo 2>/dev/null
                      read -r FLEET_SUDOPASS < /dev/tty; stty echo 2>/dev/null; echo >&2; fi
                 shift ;;
    --uninstall) DO_UNINSTALL=1; ARGS_LEFT="--uninstall"; shift ;;
    -h|--help)   sed -n '2,26p' "$0"; exit 0 ;;
    -*)          die "opcao desconhecida: $1" ;;
    *)           echo "$1" >> "$HOSTS_FILE"; shift ;;
  esac
done

if [ -s "$HOSTS_FILE" ]; then
  N=$(wc -l < "$HOSTS_FILE" | tr -d ' ')
  curl -fsS -o /dev/null --max-time 5 "http://${FLEET_SERVER}/install-agent.sh" \
    || die "http://${FLEET_SERVER}/install-agent.sh nao responde - o container 'enroll' esta no ar?"
  if [ "$FLEET_ASKPASS" = 1 ]; then
    command -v sshpass >/dev/null || die "--ask-pass exige sshpass (apt install sshpass)"
    if [ -n "${SSH_PASSWORD:-}" ]; then FLEET_SSHPASS="$SSH_PASSWORD"
    else printf 'senha SSH: ' >&2; stty -echo 2>/dev/null
         read -r FLEET_SSHPASS < /dev/tty; stty echo 2>/dev/null; echo >&2; fi
  fi
  FLAG=""; if [ "$DO_UNINSTALL" = 1 ]; then FLAG=" -s -- --uninstall"; fi
  OUT=$(mktemp -d); trap 'rm -rf "$OUT" "$HOSTS_FILE"' EXIT

  log "Servidor de enroll : http://${FLEET_SERVER}/install-agent.sh"
  log "Acao               : $([ "$DO_UNINSTALL" = 1 ] && echo desinstalar || echo instalar)"
  log "Hosts              : ${N}  (paralelismo ${FLEET_JOBS})"
  echo

  i=0
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    (
      hp=${spec%%:*}; port=""; user="$FLEET_USER"
      case "$spec" in *:*) port=${spec##*:} ;; esac
      case "$hp" in *@*) user=${hp%%@*}; host=${hp#*@} ;; *) host="$hp" ;; esac
      set -- ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=10 -o LogLevel=ERROR
      if [ -n "$port" ]; then set -- "$@" -p "$port"; fi
      if [ -n "$FLEET_SSHPASS" ]; then set -- sshpass -e "$@"; fi
      REMOTE="set -e
curl -fsSL http://${FLEET_SERVER}/install-agent.sh -o /tmp/install-agent.sh
if [ -n '${FLEET_SUDOPASS}' ]; then
  echo '${FLEET_SUDOPASS}' | sudo -S -p '' sh /tmp/install-agent.sh${FLAG}
else
  sudo -n sh /tmp/install-agent.sh${FLAG}
fi
rm -f /tmp/install-agent.sh"
      safe=$(echo "$spec" | tr -c 'a-zA-Z0-9' '_')
      if SSHPASS="$FLEET_SSHPASS" "$@" "${user}@${host}" "$REMOTE" > "${OUT}/${safe}.log" 2>&1
      then echo "OK|${spec}" >> "${OUT}/result"
      else echo "FALHA|${spec}" >> "${OUT}/result"; fi
    ) &
    i=$((i+1))
    if [ $((i % FLEET_JOBS)) -eq 0 ]; then wait; fi
  done < "$HOSTS_FILE"
  wait

  # '|| true': grep -c sai 1 quando nao casa nada e, sob set -e, uma atribuicao
  # por substituicao que falha aborta o script - o resumo nunca era impresso.
  OKN=$(grep -c '^OK|'    "${OUT}/result" 2>/dev/null || true); OKN=${OKN:-0}
  BADN=$(grep -c '^FALHA|' "${OUT}/result" 2>/dev/null || true); BADN=${BADN:-0}
  echo "==========================================================="
  printf ' Resultado: %s ok, %s falha(s), de %s host(s)\n' "$OKN" "$BADN" "$N"
  echo "==========================================================="
  if [ "$BADN" -gt 0 ]; then
    echo; echo "Falhas (ultimas linhas de cada):"
    grep '^FALHA|' "${OUT}/result" | cut -d'|' -f2 | while read -r h; do
      echo "--- $h"
      tail -4 "${OUT}/$(echo "$h" | tr -c 'a-zA-Z0-9' '_').log" 2>/dev/null | sed 's/^/    /'
    done
  fi
  if [ "$BADN" -eq 0 ]; then exit 0; else exit 1; fi
fi
set -- $ARGS_LEFT

# ===========================================================================
# MODO LOCAL: instala neste host.
# ===========================================================================
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
      # Remove restos de uma tentativa anterior ANTES do primeiro update: uma
      # sources.list.d/fluent-bit.list invalida faz o apt-get update inteiro
      # falhar ("does not have a Release file") e, com set -e, aborta o script
      # antes mesmo de reescrever o arquivo.
      rm -f /etc/apt/sources.list.d/fluent-bit.list
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg ca-certificates >/dev/null
      install -d -m 0755 /usr/share/keyrings
      curl -fsSL https://packages.fluentbit.io/fluentbit.key \
        | gpg --batch --yes --no-tty --dearmor -o /usr/share/keyrings/fluentbit-keyring.gpg
      CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo jammy)}"
      # O repo do Fluent Bit publica em /<distro>/<codename>/dists/<codename>/ -
      # o codename entra DUAS vezes. Sem o codename no caminho o apt-get update
      # falha com "does not have a Release file".
      echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/${ID}/${CODENAME} ${CODENAME} main" \
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
