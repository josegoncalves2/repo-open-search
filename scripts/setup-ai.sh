#!/usr/bin/env bash
# ===========================================================================
# setup-ai.sh - provisiona IA generativa / Agentic / LLM no OpenSearch
#
#   1. Connector OpenAI-compatible -> OpenRouter (chat completions)
#   2. Modelo de chat remoto (ML Commons remote model) + deploy
#   3. Modelo local de embeddings (pre-treinado do OpenSearch) + deploy
#   4. Root agent 'conversational' com tools (ListIndex/IndexMapping/Search/
#      CatIndex/PPL) + memoria de conversa
#   5. Registra o agent como root agent do OpenSearch Assistant (config 'os_chat')
#   6. Testa o agent com uma pergunta real
#
# Idempotente: reaproveita connector/modelos/agent que ja existam pelo nome.
# Requer: OS_ADMIN_PASS, LLM_API_KEY (via .env).  jq obrigatorio.
# ===========================================================================
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9200}"
OS_ADMIN_USER="${OS_ADMIN_USER:-admin}"
OS_ADMIN_PASS="${OS_ADMIN_PASS:?defina OS_ADMIN_PASS}"

LLM_PROVIDER="${LLM_PROVIDER:-openrouter}"
LLM_ENDPOINT="${LLM_ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}"
LLM_MODEL="${LLM_MODEL:-minimax/minimax-m3:free}"
LLM_API_KEY="${LLM_API_KEY:?defina LLM_API_KEY}"

EMBEDDING_MODEL="${EMBEDDING_MODEL:-huggingface/sentence-transformers/all-MiniLM-L6-v2}"
EMBEDDING_VERSION="${EMBEDDING_VERSION:-1.0.2}"

CONNECTOR_NAME="${LLM_PROVIDER}-chat-connector"
LLM_MODEL_NAME="${LLM_PROVIDER}:${LLM_MODEL}"
AGENT_NAME="OpenSearch Assistant Root Agent"

command -v jq >/dev/null || { echo "jq obrigatorio"; exit 1; }
api() { curl -sk -u "${OS_ADMIN_USER}:${OS_ADMIN_PASS}" -H 'Content-Type: application/json' "$@"; }

wait_model() {  # $1 = model_id ; espera model_state == DEPLOYED / REGISTERED
  local mid="$1" st
  for _ in $(seq 1 60); do
    st=$(api "${OS_URL}/_plugins/_ml/models/${mid}" | jq -r '.model_state // "??"')
    case "$st" in
      DEPLOYED|REGISTERED|PARTIALLY_DEPLOYED) echo "$st"; return 0 ;;
      DEPLOY_FAILED|REGISTER_FAILED)          echo "$st"; return 1 ;;
    esac
    sleep 10
  done
  echo "$st"; return 1
}

# --------------------------------------------------------------------------
echo "==> 0. Cluster settings de ML (endpoints confiaveis, memoria, RAG)"
api -XPUT "${OS_URL}/_cluster/settings" -d "{
  \"persistent\": {
    \"plugins.ml_commons.trusted_connector_endpoints_regex\": [
      \"^https://openrouter\\\\.ai/.*$\",
      \"^https://api\\\\.openai\\\\.com/.*$\",
      \"^https://api\\\\.cohere\\\\.ai/.*$\",
      \"^https://bedrock-runtime\\\\..*\\\\.amazonaws\\\\.com/.*$\",
      \"^https://generativelanguage\\\\.googleapis\\\\.com/.*$\"
    ],
    \"plugins.ml_commons.only_run_on_ml_node\": false,
    \"plugins.ml_commons.model_access_control_enabled\": false,
    \"plugins.ml_commons.connector_access_control_enabled\": false,
    \"plugins.ml_commons.memory_feature_enabled\": true,
    \"plugins.ml_commons.rag_pipeline_feature_enabled\": true,
    \"plugins.ml_commons.agent_framework_enabled\": true,
    \"plugins.ml_commons.native_memory_threshold\": 100,
    \"plugins.ml_commons.jvm_heap_memory_threshold\": 100,
    \"plugins.ml_commons.disk_free_space_threshold\": -1,
    \"plugins.ml_commons.allow_registering_model_via_url\": true,
    \"plugins.ml_commons.ml_task_timeout_in_seconds\": 3600
  }
}" | jq -c '{acknowledged}'
# ml_task_timeout_in_seconds: o padrao (600s) NAO cobre o primeiro registro de
# um modelo local em volume novo - o ML Commons precisa baixar o modelo e o
# runtime nativo do PyTorch/DJL (centenas de MB) e descompacta-lo. Ao estourar,
# a task vira FAILED com "timeout after 600 seconds" e o agent acaba sem
# VectorDBTool. 3600s da folga; nas subidas seguintes o cache ja existe.

# --------------------------------------------------------------------------
echo "==> 1. Connector ${CONNECTOR_NAME} (OpenAI-compatible -> ${LLM_PROVIDER})"

# IMPORTANTE - formato do request_body:
# O agent do tipo 'conversational' NAO envia 'parameters.messages'; ele monta o
# prompt (ReAct + historico + tools) e passa em 'parameters.prompt'. Um connector
# com \"messages\": ${parameters.messages} registra e faz _predict manual, mas o
# _execute do agent falha com:
#   "Invalid payload: { ... \"messages\": ${parameters.messages} ... }"
# Por isso montamos o array 'messages' aqui a partir de ${parameters.prompt}.
CONNECTOR_BODY=$(cat <<JSON
{
  "name": "${CONNECTOR_NAME}",
  "description": "OpenAI-compatible chat connector para ${LLM_PROVIDER} (${LLM_MODEL})",
  "version": 2,
  "protocol": "http",
  "parameters": {
    "endpoint": "${LLM_ENDPOINT}",
    "model": "${LLM_MODEL}",
    "temperature": 0,
    "max_tokens": 1024
  },
  "credential": { "api_key": "${LLM_API_KEY}" },
  "actions": [{
    "action_type": "predict",
    "method": "POST",
    "url": "${LLM_ENDPOINT}",
    "headers": {
      "Authorization": "Bearer \${credential.api_key}",
      "Content-Type": "application/json"
    },
    "request_body": "{ \\"model\\": \\"\${parameters.model}\\", \\"messages\\": [{\\"role\\":\\"user\\",\\"content\\":\\"\${parameters.prompt}\\"}], \\"temperature\\": \${parameters.temperature}, \\"max_tokens\\": \${parameters.max_tokens} }"
  }]
}
JSON
)

CONNECTOR_ID=$(api "${OS_URL}/_plugins/_ml/connectors/_search" \
  -d "{\"size\":1,\"query\":{\"match_phrase\":{\"name\":\"${CONNECTOR_NAME}\"}}}" \
  | jq -r '.hits.hits[0]._id // empty')

CONNECTOR_UPDATED=0
if [ -z "$CONNECTOR_ID" ]; then
  # Logo apos o boot o ML Commons pode ainda nao aceitar a criacao (indices
  # .plugins-ml-* sendo criados / cluster settings propagando). Tenta algumas
  # vezes antes de desistir - sem isso o cold start falha na 1a execucao.
  for attempt in $(seq 1 10); do
    CREATE_RESP=$(api -XPOST "${OS_URL}/_plugins/_ml/connectors/_create" \
      --data-binary "$CONNECTOR_BODY")
    CONNECTOR_ID=$(echo "$CREATE_RESP" | jq -r '.connector_id // empty')
    [ -n "$CONNECTOR_ID" ] && break
    echo "    tentativa ${attempt}/10 falhou: $(echo "$CREATE_RESP" | head -c 200)"
    sleep 6
  done
  if [ -z "$CONNECTOR_ID" ]; then
    echo "    FALHA ao criar connector apos 10 tentativas. Ultima resposta:"
    echo "    $CREATE_RESP"
  else
    echo "    connector criado: ${CONNECTOR_ID}"
  fi
else
  # Idempotencia real: reaproveitar o connector pelo nome deixaria uma definicao
  # antiga (ex.: com 'messages') no ar para sempre. Atualiza sempre.
  # Um connector EM USO por um modelo deployado recusa o PUT com HTTP 400
  # ("N models are still using this connector"). Undeploy antes; o passo 2
  # redeploya (CONNECTOR_UPDATED=1).
  # 'connector_id' e campo text (analisado) -> 'term' nao casa o id com '-' e
  # maiusculas; usar 'match'.
  undeployed_any=0
  for mid in $(api "${OS_URL}/_plugins/_ml/models/_search" \
        -d "{\"size\":20,\"_source\":[\"model_state\"],\"query\":{\"match\":{\"connector_id\":\"${CONNECTOR_ID}\"}}}" \
        | jq -r '.hits.hits[] | select(._source.model_state=="DEPLOYED" or ._source.model_state=="PARTIALLY_DEPLOYED") | ._id'); do
    echo "    undeploy do modelo ${mid} (usa este connector)"
    api -XPOST "${OS_URL}/_plugins/_ml/models/${mid}/_undeploy" >/dev/null 2>&1 || true
    undeployed_any=1
  done
  [ "$undeployed_any" = 1 ] && sleep 3
  api -XPUT "${OS_URL}/_plugins/_ml/connectors/${CONNECTOR_ID}" \
    --data-binary "$CONNECTOR_BODY" | jq -c '{result: (.result // .status // "updated")}'
  CONNECTOR_UPDATED=1
  echo "    connector atualizado: ${CONNECTOR_ID}"
fi
[ -n "$CONNECTOR_ID" ] && [ "$CONNECTOR_ID" != null ] || { echo "FALHA: sem connector_id"; exit 1; }

# --------------------------------------------------------------------------
echo "==> 2. Modelo de chat remoto (${LLM_MODEL_NAME})"
LLM_MODEL_ID=$(api "${OS_URL}/_plugins/_ml/models/_search" \
  -d "{\"size\":1,\"query\":{\"bool\":{\"must\":[
        {\"match_phrase\":{\"name\":\"${LLM_MODEL_NAME}\"}},
        {\"terms\":{\"model_state\":[\"DEPLOYED\",\"REGISTERED\",\"PARTIALLY_DEPLOYED\"]}}]}}}" \
  | jq -r '.hits.hits[0]._id // empty')

if [ -z "$LLM_MODEL_ID" ]; then
  LLM_MODEL_ID=$(api -XPOST "${OS_URL}/_plugins/_ml/models/_register?deploy=true" -d "{
    \"name\": \"${LLM_MODEL_NAME}\",
    \"function_name\": \"remote\",
    \"description\": \"Chat LLM via ${LLM_PROVIDER}\",
    \"connector_id\": \"${CONNECTOR_ID}\"
  }" | jq -r '.model_id')
  echo "    modelo registrado: ${LLM_MODEL_ID} -> $(wait_model "$LLM_MODEL_ID")"
else
  echo "    modelo ja existe: ${LLM_MODEL_ID}"
  if [ "$CONNECTOR_UPDATED" = 1 ]; then
    echo "    connector mudou -> redeploy do modelo para recarregar a definicao"
    api -XPOST "${OS_URL}/_plugins/_ml/models/${LLM_MODEL_ID}/_undeploy" >/dev/null || true
    sleep 2
    api -XPOST "${OS_URL}/_plugins/_ml/models/${LLM_MODEL_ID}/_deploy" >/dev/null || true
    echo "    estado: $(wait_model "$LLM_MODEL_ID" || true)"
  fi
fi

# --------------------------------------------------------------------------
echo "==> 3. Modelo local de embeddings (${EMBEDDING_MODEL} v${EMBEDDING_VERSION})"
EMB_MODEL_ID=$(api "${OS_URL}/_plugins/_ml/models/_search" \
  -d "{\"size\":1,\"query\":{\"bool\":{\"must\":[
        {\"match_phrase\":{\"name\":\"${EMBEDDING_MODEL}\"}},
        {\"terms\":{\"model_state\":[\"DEPLOYED\",\"REGISTERED\",\"PARTIALLY_DEPLOYED\"]}}]}}}" \
  | jq -r '.hits.hits[0]._id // empty')

# O 1o registro em volume novo baixa o modelo + o runtime nativo do PyTorch/DJL
# (centenas de MB) e descompacta. Pode levar 10-30min em host modesto. Por isso:
# espera longa, com estado visivel, e 1 nova tentativa se a task falhar (o que
# ja baixou fica em cache, entao a 2a passa e bem mais rapida).
register_embeddings() {   # imprime o task_id
  api -XPOST "${OS_URL}/_plugins/_ml/models/_register?deploy=true" -d "{
    \"name\": \"${EMBEDDING_MODEL}\",
    \"version\": \"${EMBEDDING_VERSION}\",
    \"model_format\": \"TORCH_SCRIPT\"
  }" | jq -r '.task_id // empty'
}

wait_task() {   # $1 = task_id ; imprime "<state>|<model_id>" ; 0 se COMPLETED
  local tid="$1" line st mid
  for _ in $(seq 1 240); do    # 240 x 15s = 60min
    line=$(api "${OS_URL}/_plugins/_ml/tasks/${tid}" \
             | jq -r '"\(.state // "??")|\(.model_id // "")"')
    st=${line%%|*}; mid=${line#*|}
    case "$st" in
      COMPLETED)                    echo "${st}|${mid}"; return 0 ;;
      FAILED|COMPLETED_WITH_ERROR)  echo "${st}|${mid}"; return 1 ;;
    esac
    sleep 15
  done
  echo "TIMEOUT|${mid}"; return 1
}

if [ -z "$EMB_MODEL_ID" ]; then
  for attempt in 1 2; do
    TASK_ID=$(register_embeddings)
    if [ -z "$TASK_ID" ]; then
      echo "    aviso: registro do modelo de embeddings nao retornou task_id"
      break
    fi
    echo "    tentativa ${attempt}: task ${TASK_ID} (baixa modelo + runtime PyTorch; pode demorar)"
    RES=$(wait_task "$TASK_ID") && RC=0 || RC=1
    ST=${RES%%|*}; MID=${RES#*|}
    if [ "$RC" = 0 ] && [ -n "$MID" ]; then
      EMB_MODEL_ID="$MID"
      echo "    embeddings: ${EMB_MODEL_ID} -> $(wait_model "$EMB_MODEL_ID" || true)"
      break
    fi
    echo "    tentativa ${attempt} terminou em '${ST}'"
  done
  [ -n "${EMB_MODEL_ID:-}" ] || echo "    AVISO: embeddings nao registraram - o agent fica SEM VectorDBTool. Reexecute com 'docker compose up -d --force-recreate provisioner' (o que ja baixou fica em cache)."
else
  echo "    embeddings ja existe: ${EMB_MODEL_ID}"
fi

# --------------------------------------------------------------------------
echo "==> 4. Root agent '${AGENT_NAME}'"

# As tools disponiveis mudam entre versoes (ex.: CatIndexTool NAO existe no
# OpenSearch 3.8 e faz o _execute falhar com "Tool type not found" mesmo que o
# registro do agent tenha dado certo). Por isso montamos a lista a partir do
# que o proprio cluster expoe em GET /_plugins/_ml/tools.
AVAILABLE=$(api "${OS_URL}/_plugins/_ml/tools" | jq -r '.[].type' 2>/dev/null)
[ -n "$AVAILABLE" ] || { echo "FALHA: nao consegui listar /_plugins/_ml/tools"; exit 1; }
has_tool() { echo "$AVAILABLE" | grep -qx "$1"; }

TOOLS=""
add_tool() {  # $1 = type ; $2 = json completo da tool
  if has_tool "$1"; then
    TOOLS="${TOOLS}${TOOLS:+,}$2"
  else
    echo "    (pulando ${1}: indisponivel nesta versao)"
  fi
}

# 'indices' fixo em "*,-.*": no OpenSearch 3.8 o ListIndexTool usa a API
# paginada GET /_list/indices, e ela responde 403 ("no permissions for []")
# quando o alvo resolve indices de sistema (.*). Restringindo a nao-sistema,
# GET /_list/indices/*,-.* responde 200.
add_tool ListIndexTool    '{ "type": "ListIndexTool", "name": "ListIndexTool", "parameters": { "indices": ["*", "-.*"] } }'
add_tool IndexMappingTool '{ "type": "IndexMappingTool", "name": "IndexMappingTool" }'
add_tool SearchIndexTool  '{ "type": "SearchIndexTool", "name": "SearchIndexTool" }'
add_tool CatIndexTool     '{ "type": "CatIndexTool", "name": "CatIndexTool" }'
if [ -n "${EMB_MODEL_ID:-}" ] && [ "${EMB_MODEL_ID}" != null ]; then
  add_tool VectorDBTool "{ \"type\": \"VectorDBTool\", \"name\": \"VectorDBTool\", \"parameters\": { \"model_id\": \"${EMB_MODEL_ID}\", \"index\": \"*\", \"embedding_field\": \"embedding\", \"source_field\": [\"text\"], \"input\": \"\${parameters.question}\" } }"
fi
add_tool PPLTool "{ \"type\": \"PPLTool\", \"name\": \"PPLTool\", \"parameters\": { \"model_id\": \"${LLM_MODEL_ID}\", \"model_type\": \"OPENAI\", \"execute\": true } }"

echo "    tools do agent: $(echo "[${TOOLS}]" | jq -r '[.[].type] | join(", ")')"

AGENT_ID=$(api -XGET "${OS_URL}/_plugins/_ml/agents/_search" \
  -d "{\"size\":1,\"query\":{\"match_phrase\":{\"name\":\"${AGENT_NAME}\"}},\"sort\":[{\"created_time\":{\"order\":\"desc\"}}]}" \
  | jq -r '.hits.hits[0]._id // empty')

register_agent() {
  api -XPOST "${OS_URL}/_plugins/_ml/agents/_register" -d "{
    \"name\": \"${AGENT_NAME}\",
    \"type\": \"conversational\",
    \"description\": \"Root agent do OpenSearch Assistant (Dashboards)\",
    \"llm\": {
      \"model_id\": \"${LLM_MODEL_ID}\",
      \"parameters\": {
        \"max_iteration\": 5,
        \"response_filter\": \"\$.choices[0].message.content\",
        \"message_history_limit\": 5,
        \"disable_trace\": true
      }
    },
    \"memory\": { \"type\": \"conversation_index\" },
    \"tools\": [ ${TOOLS} ],
    \"app_type\": \"os_chat\"
  }" | jq -r '.agent_id'
}

if [ -z "$AGENT_ID" ]; then
  AGENT_ID=$(register_agent)
  echo "    agent criado: ${AGENT_ID}"
else
  echo "    agent ja existe: ${AGENT_ID} (recriando para pegar modelos atuais)"
  AGENT_ID=$(register_agent)
  echo "    novo agent: ${AGENT_ID}"
fi
[ -n "$AGENT_ID" ] && [ "$AGENT_ID" != null ] || { echo "FALHA: sem agent_id"; exit 1; }

# --------------------------------------------------------------------------
echo "==> 5. Registrando '${AGENT_ID}' como root agent do Assistant (os_chat)"
# Os indices .plugins-ml-* sao system indices protegidos: nem all_access os
# acessa. Requer o node setting plugins.security.system_indices.permission.enabled
# =true (ja no docker-compose.yml) + uma role com 'system:admin/system_index'.
# ATENCAO: o escopo tem de ser .plugins-ml-* (nao so .plugins-ml-config), senao
# com a permission feature ligada o proprio _plugins/_ml/models/_search da 403.
api -XPUT "${OS_URL}/_plugins/_security/api/roles/ml-config-writer" -d '{
  "cluster_permissions": [],
  "index_permissions": [{
    "index_patterns": [".plugins-ml-*"],
    "allowed_actions": ["system:admin/system_index"]
  }]
}' | jq -c '{status}' 2>/dev/null || true
api -XPUT "${OS_URL}/_plugins/_security/api/rolesmapping/ml-config-writer" \
  -d "{\"users\":[\"${OS_ADMIN_USER}\"]}" | jq -c '{status}' 2>/dev/null || true
sleep 2
CFG=$(api -XPUT "${OS_URL}/.plugins-ml-config/_doc/os_chat" -d "{
  \"type\": \"os_chat_root_agent\",
  \"configuration\": { \"agent_id\": \"${AGENT_ID}\" }
}")
if echo "$CFG" | jq -e '.result // empty' >/dev/null 2>&1; then
  echo "    os_chat -> $(echo "$CFG" | jq -r '.result')"
else
  echo "    aviso: nao consegui gravar em .plugins-ml-config diretamente:"
  echo "    $CFG"
  echo "    -> defina o Root agent manualmente no Dashboards:"
  echo "       Assistant -> Settings -> Root agent id = ${AGENT_ID}"
fi

# --------------------------------------------------------------------------
echo "==> 5b. Agentes de resumo do Assistant (os_summary / os_summary_with_log_pattern)"
# Sem estes, o Dashboards loga a cada navegacao que usa 'Summarize':
#   [status_exception]: Failed to find config with the provided config id: os_summary
# Sao flow agents simples com um MLModelTool apontando para o mesmo LLM.
register_flow_summary() {  # $1 = nome amigavel
  api -XPOST "${OS_URL}/_plugins/_ml/agents/_register" -d "{
    \"name\": \"$1\",
    \"type\": \"flow\",
    \"description\": \"Flow agent de resumo do OpenSearch Assistant\",
    \"tools\": [{
      \"type\": \"MLModelTool\",
      \"name\": \"ml_model_tool\",
      \"description\": \"Resume o contexto fornecido\",
      \"parameters\": {
        \"model_id\": \"${LLM_MODEL_ID}\",
        \"prompt\": \"Voce e o OpenSearch Assistant. Resuma de forma objetiva, em portugues, o conteudo a seguir. Se houver uma pergunta, responda-a com base nele.\\n\\nContexto:\\n\${parameters.context}\\n\\nPergunta: \${parameters.question}\\n\\nResumo:\"
      }
    }]
  }" | jq -r '.agent_id // empty'
}

for cfg in os_summary os_summary_with_log_pattern; do
  existing=$(api "${OS_URL}/.plugins-ml-config/_doc/${cfg}" | jq -r '._source.configuration.agent_id // empty')
  if [ -n "$existing" ] && api "${OS_URL}/_plugins/_ml/agents/${existing}" | jq -e '.type' >/dev/null 2>&1; then
    echo "    ${cfg} ja aponta para agent valido (${existing})"
    continue
  fi
  said=$(register_flow_summary "OpenSearch Assistant Summary Agent (${cfg})")
  if [ -n "$said" ] && [ "$said" != null ]; then
    r=$(api -XPUT "${OS_URL}/.plugins-ml-config/_doc/${cfg}" -d "{
      \"type\": \"${cfg}\",
      \"configuration\": { \"agent_id\": \"${said}\" }
    }" | jq -r '.result // .status // "?"')
    echo "    ${cfg} -> agent ${said} (${r})"
  else
    echo "    aviso: nao consegui registrar o agent para ${cfg}"
  fi
done

# --------------------------------------------------------------------------
# Semeia um indice minimo. Alem de dar dado real para o Dashboards, evita que
# ListIndexTool/PPLTool logem ERROR ("Failed to fetch index info for page: null")
# quando o agent e exercitado num cluster totalmente vazio.
echo "==> 5c. Indice de amostra 'sample-logs'"
if ! api -o /dev/null -w '%{http_code}' "${OS_URL}/sample-logs" | grep -q 200; then
  api -XPUT "${OS_URL}/sample-logs" -d '{
    "settings": { "number_of_replicas": 0 },
    "mappings": { "properties": {
      "@timestamp": { "type": "date" },
      "level": { "type": "keyword" },
      "service": { "type": "keyword" },
      "message": { "type": "text" }
    }}
  }' | jq -c '{acknowledged}' 2>/dev/null || true
  api -XPOST "${OS_URL}/sample-logs/_bulk" --data-binary '
{"index":{}}
{"@timestamp":"2026-09-03T12:00:00Z","level":"INFO","service":"api","message":"stack provisionada"}
{"index":{}}
{"@timestamp":"2026-09-03T12:01:00Z","level":"WARN","service":"api","message":"exemplo de aviso"}
{"index":{}}
{"@timestamp":"2026-09-03T12:02:00Z","level":"ERROR","service":"worker","message":"exemplo de erro"}
' | jq -c '{errors}' 2>/dev/null || true
  api -XPOST "${OS_URL}/sample-logs/_refresh" >/dev/null 2>&1 || true
  echo "    sample-logs criado (3 docs)"
else
  echo "    sample-logs ja existe"
fi

# --------------------------------------------------------------------------
echo "==> 6. Teste do agent (pergunta real)"
TEST=$(api -XPOST "${OS_URL}/_plugins/_ml/agents/${AGENT_ID}/_execute" -d '{
  "parameters": { "question": "Quantos indices existem neste cluster? Responda em uma frase." }
}')
# A resposta do agent conversacional vem em output[].dataAsMap.response;
# 'output[0].result' e o memory_id, nao o texto.
echo "$TEST" | jq -r '
  [.inference_results[0].output[]?
   | select(.name=="response")
   | (.dataAsMap.response // .result)] | first
  // "<sem resposta> "+(.|tostring)' | head -c 800
echo

cat <<FIM

===========================================================================
 IA / Agentic / LLM provisionados
---------------------------------------------------------------------------
 Connector       : ${CONNECTOR_ID}
 LLM model       : ${LLM_MODEL_ID}    (${LLM_MODEL})
 Embedding model : ${EMB_MODEL_ID:-<pendente>}
 Root agent      : ${AGENT_ID}
 Assistant       : Dashboards -> icone do Assistant (chat) / Observability -> Query Assist
===========================================================================
FIM
