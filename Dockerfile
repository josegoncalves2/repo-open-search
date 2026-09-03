# ===========================================================================
# Imagem OpenSearch da stack — deriva da oficial e corrige, na própria imagem,
# o ruído de boot que NÃO dá para resolver por configuração.
#
# Cada RUN abaixo elimina linhas de WARNING/WARN do log de inicialização.
# Detalhe do porquê de cada uma: README, seção "Logs limpos".
# ===========================================================================
ARG OPENSEARCH_VERSION=3.8.0
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION}

# Versões dos slf4j-api que a imagem embarca (conferir com:
#   for d in plugins/*/; do ls $d | grep '^slf4j-api-'; done )
ARG SLF4J_2X=2.0.17
ARG SLF4J_1X=1.7.36

USER opensearch
WORKDIR /usr/share/opensearch

# ---------------------------------------------------------------------------
# 1. Performance Analyzer — a imagem 3.8.0 NÃO traz os arquivos de config do
#    plugin (performance-analyzer.properties, plugin-stats-metadata), então ele
#    cospe 2 ERROR + stacktrace no boot e em seguida se auto-desabilita.
#    Nada nesta stack usa PA.
# ---------------------------------------------------------------------------
RUN opensearch-plugin remove opensearch-performance-analyzer

# ---------------------------------------------------------------------------
# 2. Diretório dos certificados publicados para o provisioner.
#    Criado aqui, com dono 'opensearch', porque um volume nomeado montado sobre
#    um caminho que NÃO existe na imagem nasce root:root — e o entrypoint (que
#    roda como opensearch) não conseguiria copiar os certos para lá.
# ---------------------------------------------------------------------------
USER root
RUN mkdir -p /certs && chown opensearch:opensearch /certs && chmod 700 /certs
USER opensearch

# ---------------------------------------------------------------------------
# NÃO removemos '--add-modules=jdk.incubator.vector' do config/jvm.options.
# Tirar troca 3 linhas de aviso por 2 — e as 2 são o Lucene reclamando que o
# módulo falta ("Java vector incubator module is not readable. For optimal
# vector performance, pass '--add-modules jdk.incubator.vector'") — além de
# desligar o SIMD/Panama, que é justamente o que acelera k-NN e neural search.
# Ficam então 3 linhas de WARNING do launcher do JDK 25, sem como silenciar:
# são o JDK anunciando um módulo incubator que o OpenSearch usa de propósito.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 3. SLF4J sem provider — vários plugins da imagem embarcam slf4j-api (1.7 e
#    2.x) sem nenhum binding no mesmo classloader. O SLF4J então imprime 6
#    linhas em stderr e cai para NOP.
#    Adicionamos slf4j-nop: o comportamento efetivo é EXATAMENTE o de hoje
#    (no-op), só que explícito e silencioso — nenhum log passa a ser descartado
#    que já não estivesse sendo.
# ---------------------------------------------------------------------------
RUN set -eu; \
    base="https://repo1.maven.org/maven2/org/slf4j/slf4j-nop"; \
    curl -fsSL -o /tmp/nop2.jar "${base}/${SLF4J_2X}/slf4j-nop-${SLF4J_2X}.jar"; \
    curl -fsSL -o /tmp/nop1.jar "${base}/${SLF4J_1X}/slf4j-nop-${SLF4J_1X}.jar"; \
    for p in opensearch-alerting \
             opensearch-anomaly-detection \
             opensearch-flow-framework \
             opensearch-knn \
             opensearch-ltr \
             opensearch-notifications-core; do \
      cp /tmp/nop2.jar "plugins/${p}/slf4j-nop-${SLF4J_2X}.jar"; \
    done; \
    cp /tmp/nop1.jar "plugins/opensearch-sql/slf4j-nop-${SLF4J_1X}.jar"; \
    rm -f /tmp/nop1.jar /tmp/nop2.jar

# O entrypoint (scripts/opensearch-entrypoint.sh) continua vindo por volume do
# docker-compose.yml — ele depende de coisas que só existem em runtime
# (instalador demo, senha de bootstrap).
