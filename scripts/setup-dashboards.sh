#!/usr/bin/env bash
# ===========================================================================
# setup-dashboards.sh - objetos do OpenSearch Dashboards (index patterns).
#
# POR QUE EXISTE
# --------------
# O 'provisioner' roda ANTES do Dashboards subir (o Dashboards depende dele
# com service_completed_successfully), entao ele nao consegue criar saved
# objects. Sem um index pattern para 'logs-*', os dados dos agentes chegam ao
# OpenSearch mas o Discover mostra tela vazia - o dado existe e ninguem ve.
#
# Este script roda no servico 'dashboards-init', depois do Dashboards healthy.
# Idempotente: o PUT do saved object usa id fixo e sobrescreve.
# ===========================================================================
set -euo pipefail

OSD_URL="${OSD_URL:-http://opensearch-dashboards:5601}"
OSD_USER="${OSD_USER:?defina OSD_USER}"
OSD_PASS="${OSD_PASS:?defina OSD_PASS}"

log()  { printf '\033[1;32m[dashboards]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dashboards]\033[0m %s\n' "$*"; }

osd() {
  curl -s -u "${OSD_USER}:${OSD_PASS}" \
       -H 'osd-xsrf: true' -H 'Content-Type: application/json' "$@"
}

# --------------------------- espera o Dashboards ---------------------------
log "Aguardando ${OSD_URL}"
ok=""
for _ in $(seq 1 60); do
  if osd -o /dev/null -w '%{http_code}' "${OSD_URL}/api/status" | grep -q 200; then ok=1; break; fi
  sleep 5
done
[ -n "$ok" ] || { warn "Dashboards nao respondeu a tempo - pulando"; exit 0; }

# --------------------------- index patterns --------------------------------
# ATENCAO: nao basta criar o saved object so com title/timeFieldName. O OSD 3.8
# espera tambem o atributo 'fields' (lista de campos serializada) e
# 'fieldFormatMap'; sem eles varias telas quebram com
#   "Cannot parse datasources from saved object" / "\"undefined\" is not valid JSON".
# A lista de campos vem do proprio Dashboards, via _fields_for_wildcard.
META="meta_fields=_source&meta_fields=_id&meta_fields=_index&meta_fields=_score&meta_fields=_type"

create_pattern() {  # $1=id  $2=title  $3=time field
  local id="$1" title="$2" tf="$3" fields payload r
  fields=$(osd "${OSD_URL}/api/index_patterns/_fields_for_wildcard?pattern=$(printf '%s' "$title" | sed 's/\*/%2A/g')&${META}" \
           | jq -c '.fields // empty')
  if [ -z "$fields" ] || [ "$fields" = "null" ]; then
    warn "sem campos para '${title}' (o indice ja existe e tem dados?) - criando mesmo assim"
    fields='[]'
  fi
  payload=$(jq -nc --arg t "$title" --arg tf "$tf" --argjson f "$fields" \
    '{attributes:{title:$t, timeFieldName:$tf, fields:($f|tostring), fieldFormatMap:"{}"}}')
  r=$(osd -XPOST "${OSD_URL}/api/saved_objects/index-pattern/${id}?overwrite=true" -d "$payload")
  if echo "$r" | grep -q '"id"'; then
    log "index pattern '${title}' ok ($(echo "$fields" | jq 'length') campos)"
  else
    warn "falha em '${title}': $(echo "$r" | head -c 200)"
  fi
}

create_pattern logs-star   'logs-*'      '@timestamp'
create_pattern sample-logs 'sample-logs' '@timestamp'

# 'logs-*' como padrao do Discover
if osd -XPOST "${OSD_URL}/api/opensearch-dashboards/settings/defaultIndex" \
      -d '{"value":"logs-star"}' -o /dev/null -w '%{http_code}' | grep -q 200; then
  log "index pattern padrao: logs-*"
else
  warn "nao consegui definir o index pattern padrao"
fi

# --------------------------- visualizacoes + dashboard ---------------------
# Tela "Agentes": quem esta reportando, quanto, e quando foi o ultimo evento.
# Depende do index template (scripts/setup-logs.sh) ter feito agent_hostname
# virar 'keyword' - em 'text' as agregacoes abaixo falham.
log "Criando visualizacoes e o dashboard 'Agentes'"

# O 'index' do index pattern vai DENTRO do searchSourceJSON (nao so via
# 'references'). Objetos criados pela UI de verdade (ex.: as amostras
# "Add sample data", confirmadas renderizando) gravam
# searchSourceJSON:{"index":"<id>",...} com references:[] vazio - a
# indirecao "kibanaSavedObjectMeta.searchSourceJSON.index" + references so e
# resolvida no fluxo de save/load da propria app; via POST direto na API,
# esse inject NUNCA roda, e o Vis fica sem indexPattern -> painel quebra com
# "Trying to initialize aggs without index pattern". Comparado byte a byte
# contra '(Metric) Unique visitors' (mesmo tipo, confirmado funcionando) para
# achar a diferenca. references fica so como metadado de relacionamento.
IDXREF='[{"name":"kibanaSavedObjectMeta.searchSourceJSON.index","type":"index-pattern","id":"logs-star"}]'
SRC='{\"index\":\"logs-star\",\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}'

put_vis() {  # $1=id  $2=titulo  $3=visState(json escapado)
  osd -XPOST "${OSD_URL}/api/saved_objects/visualization/$1?overwrite=true" -d "{
    \"attributes\": {
      \"title\": \"$2\",
      \"visState\": \"$3\",
      \"uiStateJSON\": \"{}\",
      \"description\": \"\",
      \"kibanaSavedObjectMeta\": { \"searchSourceJSON\": \"${SRC}\" }
    },
    \"references\": ${IDXREF}
  }" >/dev/null && log "  visualizacao '$2'" || warn "  falhou: $2"
}

# 1) total de eventos
put_vis agentes-total "Agentes - total de eventos" \
'{\"title\":\"total\",\"type\":\"metric\",\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"schema\":\"metric\",\"params\":{}}],\"params\":{\"metric\":{\"percentageMode\":false,\"style\":{\"fontSize\":50},\"labels\":{\"show\":true}}}}'

# 2) hosts reportando: contagem + ultimo evento
put_vis agentes-hosts "Agentes - hosts reportando" \
'{\"title\":\"hosts\",\"type\":\"table\",\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"schema\":\"metric\",\"params\":{},\"label\":\"Eventos\"},{\"id\":\"2\",\"enabled\":true,\"type\":\"max\",\"schema\":\"metric\",\"params\":{\"field\":\"@timestamp\"},\"label\":\"Ultimo evento\"},{\"id\":\"3\",\"enabled\":true,\"type\":\"terms\",\"schema\":\"bucket\",\"params\":{\"field\":\"agent_hostname\",\"size\":200,\"order\":\"desc\",\"orderBy\":\"1\"},\"label\":\"Host\"}],\"params\":{\"perPage\":20,\"showTotal\":true,\"totalFunc\":\"sum\"}}'

# 3) eventos ao longo do tempo, por host
put_vis agentes-timeline "Agentes - eventos ao longo do tempo" \
'{\"title\":\"timeline\",\"type\":\"histogram\",\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"schema\":\"metric\",\"params\":{}},{\"id\":\"2\",\"enabled\":true,\"type\":\"date_histogram\",\"schema\":\"segment\",\"params\":{\"field\":\"@timestamp\",\"interval\":\"auto\",\"min_doc_count\":1}},{\"id\":\"3\",\"enabled\":true,\"type\":\"terms\",\"schema\":\"group\",\"params\":{\"field\":\"agent_hostname\",\"size\":10,\"order\":\"desc\",\"orderBy\":\"1\"}}],\"params\":{\"type\":\"histogram\",\"seriesParams\":[{\"type\":\"histogram\",\"mode\":\"stacked\",\"data\":{\"id\":\"1\",\"label\":\"Count\"},\"valueAxis\":\"ValueAxis-1\",\"show\":true}],\"categoryAxes\":[{\"id\":\"CategoryAxis-1\",\"type\":\"category\",\"position\":\"bottom\",\"show\":true,\"scale\":{\"type\":\"linear\"}}],\"valueAxes\":[{\"id\":\"ValueAxis-1\",\"type\":\"value\",\"position\":\"left\",\"show\":true,\"scale\":{\"type\":\"linear\"}}],\"legendPosition\":\"right\",\"addLegend\":true}}'

# 4) sistema operacional dos agentes
put_vis agentes-os "Agentes - sistema operacional" \
'{\"title\":\"os\",\"type\":\"pie\",\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"schema\":\"metric\",\"params\":{}},{\"id\":\"2\",\"enabled\":true,\"type\":\"terms\",\"schema\":\"segment\",\"params\":{\"field\":\"agent_os\",\"size\":10,\"order\":\"desc\",\"orderBy\":\"1\"}}],\"params\":{\"isDonut\":true,\"addLegend\":true,\"legendPosition\":\"right\"}}'

# --------------------------- o dashboard -----------------------------------
panel() { printf '{"version":"3.8.0","gridData":{"x":%s,"y":%s,"w":%s,"h":%s,"i":"%s"},"panelIndex":"%s","embeddableConfig":{},"panelRefName":"panel_%s"}' "$1" "$2" "$3" "$4" "$5" "$5" "$5"; }
PANELS="[$(panel 0 0 12 8 1),$(panel 12 0 36 8 2),$(panel 0 8 24 15 3),$(panel 24 8 24 15 4)]"
PANELS_ESC=$(printf '%s' "$PANELS" | sed 's/"/\\"/g')

REFS='[{"name":"panel_1","type":"visualization","id":"agentes-total"},
       {"name":"panel_2","type":"visualization","id":"agentes-os"},
       {"name":"panel_3","type":"visualization","id":"agentes-hosts"},
       {"name":"panel_4","type":"visualization","id":"agentes-timeline"}]'

if osd -XPOST "${OSD_URL}/api/saved_objects/dashboard/agentes?overwrite=true" -d "{
  \"attributes\": {
    \"title\": \"Agentes\",
    \"description\": \"Hosts com agente instalado: volume de eventos e ultimo contato\",
    \"panelsJSON\": \"${PANELS_ESC}\",
    \"optionsJSON\": \"{\\\"hidePanelTitles\\\":false,\\\"useMargins\\\":true}\",
    \"version\": 1,
    \"timeRestore\": true,
    \"timeTo\": \"now\",
    \"timeFrom\": \"now-24h\",
    \"refreshInterval\": { \"pause\": false, \"value\": 30000 },
    \"kibanaSavedObjectMeta\": { \"searchSourceJSON\": \"${SRC}\" }
  },
  \"references\": ${REFS}
}" | grep -q '"id"'; then
  log "dashboard 'Agentes' criado"
else
  warn "falha ao criar o dashboard 'Agentes'"
fi

log "Concluido."
