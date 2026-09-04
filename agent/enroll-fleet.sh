#!/usr/bin/env bash
# ===========================================================================
# enroll-fleet.sh - instala/remove o agente em VARIOS hosts de uma vez.
#
# Roda o mesmo install-agent.sh servido pelo NGINX de enroll, via SSH, em
# paralelo, e imprime um resumo do que deu certo e do que falhou.
#
#   ./enroll-fleet.sh --hosts hosts.txt
#   ./enroll-fleet.sh --hosts hosts.txt --uninstall
#   ./enroll-fleet.sh web1 web2 db1                 # hosts inline
#
# hosts.txt: um por linha, formato [usuario@]host[:porta]
#            linhas vazias e comecadas por '#' sao ignoradas.
#
# Autenticacao SSH:
#   - por chave (padrao): use --user/-u e tenha a chave no agente ssh;
#   - por senha: --ask-pass (pede uma vez, usa em todos; requer sshpass).
# Sudo remoto: --sudo-pass (pede uma vez) para hosts que exigem senha no sudo.
#
# Uso nao interativo (CI/automacao): exporte SSH_PASSWORD e/ou SUDO_PASSWORD
# antes de chamar, que as flags --ask-pass/--sudo-pass leem dali sem perguntar.
# ===========================================================================
set -uo pipefail

SERVER="${ENROLL_SERVER:-}"                # host que serve o install-agent.sh
SSH_USER="${SSH_USER:-$USER}"
JOBS="${JOBS:-10}"
ACTION=install
HOSTS=()
ASK_PASS=0
SUDO_PASS=""
SSH_PASS=""
declare -A EXTRA_ENV=()

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }

usage() { sed -n '2,22p' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --hosts)     [ -r "${2:-}" ] || die "arquivo de hosts ilegivel: ${2:-}"
                 while IFS= read -r l; do
                   l="${l%%#*}"; l="$(echo "$l" | tr -d '[:space:]')"
                   [ -n "$l" ] && HOSTS+=("$l")
                 done < "$2"; shift 2 ;;
    --server)    SERVER="$2"; shift 2 ;;
    -u|--user)   SSH_USER="$2"; shift 2 ;;
    -j|--jobs)   JOBS="$2"; shift 2 ;;
    --ask-pass)  ASK_PASS=1; shift ;;
    --sudo-pass) if [ -n "${SUDO_PASSWORD:-}" ]; then SUDO_PASS="$SUDO_PASSWORD"
                 else read -r -s -p "senha do sudo remoto: " SUDO_PASS </dev/tty; echo; fi
                 shift ;;
    --env)       EXTRA_ENV["${2%%=*}"]="${2#*=}"; shift 2 ;;
    --uninstall) ACTION=uninstall; shift ;;
    -h|--help)   usage ;;
    -*)          die "opcao desconhecida: $1" ;;
    *)           HOSTS+=("$1"); shift ;;
  esac
done

[ "${#HOSTS[@]}" -gt 0 ] || die "nenhum host. Use --hosts arquivo ou passe inline. (--help)"

# Descobre o servidor de enroll se nao foi informado
if [ -z "$SERVER" ]; then
  SERVER=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$SERVER" ] || die "nao consegui descobrir o IP do servidor; use --server"
fi
curl -fsS -o /dev/null --max-time 5 "http://${SERVER}/install-agent.sh" \
  || die "http://${SERVER}/install-agent.sh nao responde - o container 'enroll' esta no ar?"

if [ "$ASK_PASS" = 1 ]; then
  command -v sshpass >/dev/null || die "--ask-pass exige sshpass (apt install sshpass)"
  if [ -n "${SSH_PASSWORD:-}" ]; then SSH_PASS="$SSH_PASSWORD"
  else read -r -s -p "senha SSH: " SSH_PASS </dev/tty; echo; fi
fi

ENVSTR=""
for k in "${!EXTRA_ENV[@]}"; do ENVSTR="${ENVSTR}${k}='${EXTRA_ENV[$k]}' "; done

FLAG=""; [ "$ACTION" = uninstall ] && FLAG=" -s -- --uninstall"
OUTDIR=$(mktemp -d); trap 'rm -rf "$OUTDIR"' EXIT

log "Servidor de enroll : http://${SERVER}/install-agent.sh"
log "Acao               : ${ACTION}"
log "Hosts              : ${#HOSTS[@]}  (paralelismo ${JOBS})"
echo

run_one() {
  local spec="$1" out="$2"
  local hostpart="${spec%%:*}" port="" user="$SSH_USER" host=""
  case "$spec" in *:*) port="${spec##*:}" ;; esac
  case "$hostpart" in *@*) user="${hostpart%%@*}"; host="${hostpart#*@}" ;; *) host="$hostpart" ;; esac

  local sshcmd=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                    -o ConnectTimeout=10 -o LogLevel=ERROR)
  [ -n "$port" ] && sshcmd+=(-p "$port")
  [ -n "$SSH_PASS" ] && sshcmd=(sshpass -e "${sshcmd[@]}")

  # baixa o instalador no alvo e executa com sudo (com ou sem senha)
  local remote="set -e
curl -fsSL http://${SERVER}/install-agent.sh -o /tmp/install-agent.sh
if [ -n '${SUDO_PASS}' ]; then
  echo '${SUDO_PASS}' | sudo -S -p '' ${ENVSTR}sh /tmp/install-agent.sh${FLAG}
else
  sudo -n ${ENVSTR}sh /tmp/install-agent.sh${FLAG}
fi
rm -f /tmp/install-agent.sh"

  if SSHPASS="$SSH_PASS" "${sshcmd[@]}" "${user}@${host}" "$remote" >"$out" 2>&1; then
    echo "OK|${spec}"
  else
    echo "FALHA|${spec}"
  fi
}

i=0
for h in "${HOSTS[@]}"; do
  run_one "$h" "${OUTDIR}/$(echo "$h" | tr -c 'a-zA-Z0-9' '_').log" >>"${OUTDIR}/result" &
  i=$((i+1))
  [ $((i % JOBS)) -eq 0 ] && wait
done
wait

OK=$(grep -c '^OK|'    "${OUTDIR}/result" 2>/dev/null); OK=${OK:-0}
BAD=$(grep -c '^FALHA|' "${OUTDIR}/result" 2>/dev/null); BAD=${BAD:-0}

echo "==========================================================="
printf " Resultado: %s ok, %s falha(s), de %s host(s)\n" "$OK" "$BAD" "${#HOSTS[@]}"
echo "==========================================================="
if [ "$BAD" -gt 0 ]; then
  echo
  echo "Falhas (ultimas linhas de cada):"
  grep '^FALHA|' "${OUTDIR}/result" | cut -d'|' -f2 | while read -r h; do
    f="${OUTDIR}/$(echo "$h" | tr -c 'a-zA-Z0-9' '_').log"
    echo "--- $h"; tail -4 "$f" 2>/dev/null | sed 's/^/    /'
  done
fi
[ "$BAD" -eq 0 ]
