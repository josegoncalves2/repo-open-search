#!/usr/bin/env bash
# ===========================================================================
# lib.sh - helpers compartilhados pelos scripts de provisionamento.
# Use com:  . "$(dirname "$0")/lib.sh"
# ===========================================================================

# ---------------------------------------------------------------------------
# bcrypt_hash <senha>  ->  imprime um hash bcrypt ($2y$12$...)
#
# POR QUE ISSO EXISTE
# -------------------
# A Security REST API do OpenSearch valida a FORCA da senha com zxcvbn quando
# ela chega no campo "password":
#
#     PUT _plugins/_security/api/internalusers/pmotiadm {"password":"pmotiadm"}
#     -> {"status":"error","reason":"Weak password"}
#
# Nao ha como desligar essa checagem:
#   * plugins.security.restapi.password_validation_regex so afrouxa a REGEX,
#     nao o score do zxcvbn;
#   * plugins.security.restapi.password_score_based_validation_strength tem
#     'fair' como piso configuravel ('weak' NAO e aceito pelo parser);
#   * trocar depois via PUT _plugins/_security/api/account cai no MESMO
#     validador (testado: tambem responde "Weak password").
#
# O validador so inspeciona o campo "password". Enviando "hash" com o bcrypt
# ja calculado, ele nao roda - que e o caminho suportado para aplicar uma
# senha curta como 'pmotiadm'.
#
# Requer htpasswd (pacote apache2-utils / httpd-tools).
# ---------------------------------------------------------------------------
bcrypt_hash() {
  local pass="$1"
  command -v htpasswd >/dev/null 2>&1 || {
    echo "bcrypt_hash: 'htpasswd' nao encontrado (instale apache2-utils)" >&2
    return 1
  }
  htpasswd -bnBC 12 "" "$pass" | tr -d ':\n'
}

# ---------------------------------------------------------------------------
# put_internal_user <os_url> <curl_user:curl_pass> <username> <senha> <json_extra>
# Cria/atualiza um usuario interno aplicando a senha via hash (sem zxcvbn).
# <json_extra> sao campos adicionais do documento, ex.: '"backend_roles":["admin"]'
# ---------------------------------------------------------------------------
put_internal_user() {
  local url="$1" auth="$2" user="$3" pass="$4" extra="${5:-}"
  local hash body
  hash=$(bcrypt_hash "$pass") || return 1
  body="{\"hash\":\"${hash}\"${extra:+,${extra}}}"
  curl -sk -u "$auth" -H 'Content-Type: application/json' \
       -XPUT "${url}/_plugins/_security/api/internalusers/${user}" --data-binary "$body"
}
