#!/usr/bin/env bash
# ===========================================================================
# opensearch-entrypoint.sh - wrapper do entrypoint oficial da imagem.
#
# Roda ANTES do OpenSearch para deixar o boot limpo:
#   1. remove o plugin Performance Analyzer (a imagem 3.8.0 nao traz os
#      arquivos de config dele -> 2 ERROR + stacktrace no boot);
#   2. executa o instalador demo de seguranca (TLS + demo users) manualmente;
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

# 1. Performance Analyzer -------------------------------------------------
opensearch-plugin remove opensearch-performance-analyzer >/dev/null 2>&1 || true

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

# 5. entrypoint oficial --------------------------------------------------
export DISABLE_INSTALL_DEMO_CONFIG=true
exec "${HOME_DIR}/opensearch-docker-entrypoint.sh" opensearch
