#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Provisiona o stack de IA generativa / Agentic / LLM do OpenSearch:
#
#   1. Cria connector OpenAI-compatible apontando para o OpenRouter
#      (variavel LLM_* no .env).  Esse connector serve qualquer modelo
#      de chat-completion disponivel em https://openrouter.ai
#
#   2. Registra o modelo de chat no ML Commons (remote model)
#
#   3. Registra o modelo local de embeddings (Hugging Face) para
#      semantic search / RAG
#
#   4. Cria o root agent com 4 tools padrao:
#        - ListIndexTool
#        - VectorDBTool (k-NN)
#        - SearchTool
#        - CatIndexTool
#      Esse e o agent usado pelo OpenSearch Assistant no Dashboards.
#
#   5. Cria o memory container (conversa com contexto) e o agent final.
# ---------------------------------------------------------------------------
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

api() {
  curl -sk -u "${OS_ADMIN_USER}:${OS_ADMIN_PASS}" \
       -H 'Content-Type: application/json' "$@"
}

j() { jq -r "$1" 2>/dev/null || python3 -c "import json,sys;print(json.load(sys.stdin)$1)" 2>/dev/null || echo ""; }

echo "==> 1. Criando connector LLM (OpenRouter, OpenAI-compatible)"
resp=$(api -XPOST "${OS_URL}/_plugins/_ml/connectors/_create" -d "{
  \"name\": \"${LLM_PROVIDER}-chat\",
  \"description\": \"Connector OpenAI-compatible para ${LLM_PROVIDER} (${LLM_MODEL})\",
  \"version\": 1,
  \"protocol\": \"http\",
  \"parameters\": {
    \"endpoint\": \"${LLM_ENDPOINT}\",
    \"model\":    \"${LLM_MODEL}\",
    \"headers\":  { \"Authorization\": \"Bearer ${LLM_API_KEY}\" }
  },
  \"credential\": { \"openAI_key\": \"${LLM_API_KEY}\" },
  \"actions\": [{
    \"action_type\": \"predict\",
    \"method\":      \"POST\",
    \"url\":         \"${LLM_ENDPOINT}\",
    \"headers\":     { \"Authorization\": \"Bearer ${LLM_API_KEY}\" },
    \"request_body\": \"{ \\\"model\\\": \\\"${LLM_MODEL}\\\", \\\"messages\\\": \\\"${parameters.messages}\\\" }\"
  }]
}")
LLM_CONNECTOR_ID=$(echo "$resp" | j '.[0].connector_id')
echo "    connector_id = ${LLM_CONNECTOR_ID}"

echo "==> 2. Registrando modelo de chat remoto"
resp=$(api -XPOST "${OS_URL}/_plugins/_ml/models/_register?deploy=true" -d "{
  \"name\":    \"${LLM_MODEL}\",
  \"version\": \"1\",
  \"model_group_id\": \"${LLM_MODEL_GROUP:-llm-chat-group}\",
  \"function_name\": \"remote\",
  \"description\": \"LLM remoto via ${LLM_PROVIDER}\",
  \"connector_id\": \"${LLM_CONNECTOR_ID}\"
}")
LLM_MODEL_ID=$(echo "$resp" | j '.model_id')
echo "    model_id = ${LLM_MODEL_ID}"

echo "==> 3. Registrando modelo de embeddings (Hugging Face, sentence-transformers)"
resp=$(api -XPOST "${OS_URL}/_plugins/_ml/models/_register?deploy=true" -d "{
  \"name\":        \"${EMBEDDING_MODEL}\",
  \"version\":     \"${EMBEDDING_VERSION}\",
  \"function_name\": \"TEXT_EMBEDDING\",
  \"description\": \"Modelo local de embeddings (Hugging Face)\",
  \"model_format\": \"TORCH_SCRIPT\",
  \"model_config\": {
    \"model_type\": \"bert\",
    \"embedding_dimension\": 384,
    \"framework_type\": \"sentence_transformers\"
  },
  \"url\": \"https://artifacts.opensearch.org/models/bge/${EMBEDDING_VERSION}/${EMBEDDING_MODEL##*/}.zip\"
}")
EMB_MODEL_ID=$(echo "$resp" | j '.model_id')
echo "    embedding model_id = ${EMB_MODEL_ID}"

echo "==> 4. Aguardando deploy dos modelos"
for mid in "${LLM_MODEL_ID}" "${EMB_MODEL_ID}"; do
  [ -z "${mid}" ] || [ "${mid}" = "null" ] && continue
  for i in $(seq 1 30); do
    state=$(api "${OS_URL}/_plugins/_ml/models/${mid}" | j '["model_state"]')
    [ "${state}" = "COMPLETED" ] && break
    sleep 10
  done
  echo "    ${mid} -> ${state}"
done

echo "==> 5. Criando root agent (OpenSearch Assistant)"
resp=$(api -XPOST "${OS_URL}/_plugins/_ml/agents/_register" -d "{
  \"name\": \"OpenSearch Assistant Root Agent\",
  \"description\": \"Root agent que orquestra tools para o Assistant do Dashboards\",
  \"type\": \"conversational_flow\",
  \"tools\": [
    { \"type\": \"ListIndexTool\"     },
    { \"type\": \"SearchTool\",       \"parameters\": { \"index\": \"*\" } },
    { \"type\": \"VectorDBTool\",     \"parameters\": { \"embedding_model_id\": \"${EMB_MODEL_ID}\", \"index\": \"*\" } },
    { \"type\": \"CatIndexTool\"      },
    { \"type\": \"PPLTool\"           }
  ],
  \"memory\": { \"type\": \"conversation_index\" },
  \"parameters\": { \"model_id\": \"${LLM_MODEL_ID}\" }
}")
ROOT_AGENT_ID=$(echo "$resp" | j '.agent_id')
echo "    root_agent_id = ${ROOT_AGENT_ID}"

cat <<FIM

===========================================================================
 Stack de IA provisionado
---------------------------------------------------------------------------
 LLM connector  : ${LLM_CONNECTOR_ID}
 LLM model       : ${LLM_MODEL_ID}
 Embedding model : ${EMB_MODEL_ID}
 Root agent      : ${ROOT_AGENT_ID}

 Configurar no Dashboards: Stack Management -> Plugins -> Assistant
   Root agent field = ${ROOT_AGENT_ID}
===========================================================================
FIM