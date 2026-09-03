#!/usr/bin/env bash
# ===========================================================================
# opensearch-entrypoint.sh - wrapper do entrypoint oficial da imagem.
#
# O que e corrigido NA IMAGEM (ver Dockerfile): remocao do plugin Performance
# Analyzer, do modulo jdk.incubator.vector e a adicao de slf4j-nop.
# Aqui ficam so os passos que dependem de runtime:
#   1. marca o instante de partida (o healthcheck usa para nao sondar o
#      servidor antes de a camada de seguranca poder estar pronta - senao:
#      "BackendRegistry: OpenSearch Security not initialized" no log);
#   2. executa o instalador demo de seguranca (TLS + demo users);
#   3. remove do opensearch.yml gerado as linhas que so geram ruido/DEPRECATION:
#        - node.max_local_storage_nodes  (DEPRECATION; irrelevante single-node)
#        - plugins.security.audit.type   (fica so o -E = noop, sem conflito)
#   4. aperta a permissao dos certos/scripts demo (senao: 7x WARN
#      "insecure file permissions");
#   5. entrega para o entrypoint oficial (que faz o parse de env -> -E e
#      finalmente 'exec opensearch'), com DISABLE_INSTALL_DEMO_CONFIG=true
#      para ele nao repetir o passo 2.
# ===========================================================================
set -euo pipefail

HOME_DIR=/usr/share/opensearch
CFG="${HOME_DIR}/config"
SEC_TOOL="${HOME_DIR}/plugins/opensearch-security/tools/install_demo_configuration.sh"
START_STAMP=/tmp/.opensearch-start-epoch

# 1. marca de partida (lida pelo healthcheck) -----------------------------
date +%s > "$START_STAMP" || true

# 2. instalador demo de seguranca --------------------------------------
if [ "${DISABLE_SECURITY_PLUGIN:-false}" != "true" ] \
   && [ "${DISABLE_INSTALL_DEMO_CONFIG:-false}" != "true" ] \
   && [ -f "$SEC_TOOL" ] \
   && ! grep -q "plugins.security.ssl" "${CFG}/opensearch.yml" 2>/dev/null; then
  bash "$SEC_TOOL" -y -i -s
fi

# 3. limpa o opensearch.yml gerado ------------------------------------
if [ -f "${CFG}/opensearch.yml" ]; then
  sed -i \
    -e '/^node\.max_local_storage_nodes:/d' \
    -e '/^plugins\.security\.audit\.type:/d' \
    "${CFG}/opensearch.yml"
fi

# 4. permissoes dos artefatos demo -----------------------------------
chmod 600 "${CFG}"/*.pem "${CFG}"/*.sh 2>/dev/null || true
chmod 700 "${CFG}" 2>/dev/null || true

# 4b. publica o certificado admin (kirk) para o provisioner --------------
# E o unico jeito de escrever em indice de sistema (.plugins-ml-config, onde
# mora o root agent do Assistant) sem ligar
# plugins.security.system_indices.permission.enabled - flag que faz o
# Dashboards receber 403 em qualquer listagem com curinga.
if [ -d /certs ]; then
  cp -f "${CFG}/kirk.pem" "${CFG}/kirk-key.pem" "${CFG}/root-ca.pem" /certs/ 2>/dev/null || true
  chmod 600 /certs/*.pem 2>/dev/null || true
fi

# 5. entrypoint oficial --------------------------------------------------
export DISABLE_INSTALL_DEMO_CONFIG=true
exec "${HOME_DIR}/opensearch-docker-entrypoint.sh" opensearch
