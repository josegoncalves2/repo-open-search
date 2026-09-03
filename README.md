# Stack OpenSearch — single-node, segurança ativa, IA + Agentic + LLM

Stack completa do **OpenSearch 3.8.0** (versão estável mais recente segundo
[opensearch.org/downloads](https://opensearch.org/downloads/), lançada em
2026-08-05) com OpenSearch Dashboards, provisionamento automático de
**IA generativa / Agentic / LLM** e enroll de agentes Linux/Windows.

> **Nota sobre a versão:** o prompt original pedia "2.x". A linha 2.x ainda
> recebe patches (2.19.6), mas a série estável atual é a **3.x** — esta stack
> usa 3.8.0. Para fixar 2.x, basta `OPENSEARCH_VERSION=2.19.6` no `.env`.

## Recursos habilitados

| Categoria | Plugin / Recurso | Status |
|---|---|---|
| Core | OpenSearch + Dashboards 3.8.0 | ✅ |
| Segurança | TLS + autenticação por senha (`pmotiadm` + `agent-ingest`) | ✅ |
| Segurança | Security Analytics (detecção de ameaças) | ✅ |
| Observability | Index Patterns, Logs, Metrics, Traces | ✅ |
| Observability | Query Assistant (texto → PPL) | ✅ |
| Alertas | Alerting + Notifications | ✅ |
| ML | Anomaly Detection (AD) | ✅ |
| ML | ML Commons (modelos, pipelines, RAG, memória) | ✅ |
| ML | k-NN + Neural Search (busca vetorial) | ✅ |
| IA generativa | OpenSearch Assistant (chat, text2viz, alertInsight, anomaly insights) | ✅ |
| Agentic | Root agent conversacional (ListIndex / IndexMapping / SearchIndex / VectorDB / PPL) | ✅ |
| LLM | OpenRouter (`minimax/minimax-m3:free`) via connector OpenAI-compatible | ✅ |
| Embeddings | `all-MiniLM-L6-v2` (384 dim) — local no cluster | ✅ |
| Index Management | ISM policies (rollover, retenção, snapshots) | ✅ |
| Agentes | Fluent Bit (Linux/Windows) enviando para `logs-<host>` | ✅ |
| Enroll | NGINX publicando `install-agent.{sh,ps1}` | ✅ |

Verificado em cold start (`docker compose down -v && docker compose up -d`):
cluster `green`, 26 plugins ativos, agent respondendo em linguagem natural.

## Versões das imagens

| Imagem | Versão | Observação |
|---|---|---|
| `opensearchproject/opensearch` | `3.8.0` | última estável |
| `opensearchproject/opensearch-dashboards` | `3.8.0` | casada com o core |
| `alpine` (provisioner) | `3.24` | última estável |
| `nginx` (enroll) | `1.31-alpine` | linha mainline atual |

## Credenciais

| Conta | Uso | Senha |
|---|---|---|
| `pmotiadm` | **superusuário efetivo** — login no Dashboards e na API | `pmotiadm` |
| `admin` | conta de bootstrap/emergência (reservada no OpenSearch 3.x) | `OPENSEARCH_INITIAL_ADMIN_PASSWORD` do `.env` |
| `agent-ingest` | ingestão dos agentes Fluent Bit (só `logs-*`) | `AGENT_PASS` do `.env` |

> ⚠️ `pmotiadm/pmotiadm` é uma senha fraca, adequada apenas a laboratório.
> Para expor esta stack fora do host, troque `OPENSEARCH_ADMIN_PASSWORD` no
> `.env` e rode `docker compose up -d` de novo.

### Como a senha fraca é aplicada

A Security REST API valida a força da senha com **zxcvbn** e rejeita
`pmotiadm` com `{"status":"error","reason":"Weak password"}`. Não há como
desligar essa checagem:

| Tentativa | Resultado |
|---|---|
| `plugins.security.restapi.password_validation_regex=(.*)` | afrouxa só a **regex**, não o score |
| `..._password_score_based_validation_strength=weak` | o parser **não aceita** `weak` (piso: `fair`) |
| criar com senha forte e trocar via `PUT _plugins/_security/api/account` | cai no **mesmo** validador — também rejeita |
| **enviar `hash` bcrypt em vez de `password`** | ✅ **funciona** — o validador só inspeciona `password` |

O `scripts/lib.sh` gera o bcrypt com `htpasswd -bnBC 12` e o `provision.sh`
cria o usuário com `{"hash": "$2y$12$..."}`. Ver comentários em
[`scripts/lib.sh`](scripts/lib.sh).

## Estrutura

| Arquivo | Função |
|---|---|
| `docker-compose.yml` | Stack: OpenSearch + provisioner + Dashboards + enroll |
| `.env` | Versão, senhas, heap, limites, portas, LLM (**não vai pro Git**) |
| `.env.example` | Modelo do `.env` |
| `config/opensearch_dashboards.yml` | Config do Dashboards (Assistant, Query Assist) |
| `install.sh` | Instalação em host novo (baixa o repo e sobe a stack) |
| `scripts/lib.sh` | Helpers — geração de bcrypt e criação de usuários |
| `scripts/provision.sh` | Orquestra o provisionamento pós-boot (roda no container) |
| `scripts/setup-features.sh` | Ativa features dinâmicas via cluster settings |
| `scripts/setup-agent-user.sh` | Cria usuário/role de ingestão (`logs-*`) |
| `scripts/setup-ai.sh` | Connector + modelos + root agent (IA/Agentic/LLM) |
| `agent/install-agent.sh` | Enroll Linux (Fluent Bit) |
| `agent/install-agent.ps1` | Enroll Windows (Fluent Bit) |

> Não existe `config/opensearch.yml` de propósito: montar um arquivo com
> `plugins.security.*` faz o instalador demo **pular a geração dos
> certificados TLS**, e o nó sobe com "No SSL configuration found". Os
> settings do nó vão como variáveis de ambiente no `docker-compose.yml`.

## 1. Pré-requisito do host

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
sudo sysctl --system
```

Recursos: **≥ 4 GB RAM** e 2 vCPU. Heap da JVM em 1.5 GB (`OPENSEARCH_JAVA_OPTS`)
— os modelos de ML precisam de folga além dos 512 MB do exemplo básico.

## 2. Subir a stack

```bash
cp .env.example .env      # ajuste LLM_API_KEY
docker compose up -d
docker compose ps         # todos "healthy"
```

Instalação em host novo (baixa o repositório inteiro e provisiona):

```bash
curl -fsSL https://raw.githubusercontent.com/josegoncalves2/repo-open-search/main/install.sh | bash
```

### Ordem de subida

O serviço `provisioner` roda **uma vez**, depois que o OpenSearch fica
`healthy`, e o Dashboards só inicia quando ele termina com sucesso:

1. cria o superusuário `pmotiadm` (hash bcrypt) com `all_access`
2. `setup-features.sh` — features dinâmicas + verificação
3. `setup-agent-user.sh` — usuário de ingestão
4. `setup-ai.sh` — connector, modelos, root agent, teste real do agent

## 3. Acesso

| Serviço | Endereço | Credenciais |
|---|---|---|
| Dashboards | http://localhost:5601 | `pmotiadm` / `pmotiadm` |
| API OpenSearch | https://localhost:9200 | idem (TLS autoassinado → `curl -k`) |
| Enroll | http://localhost/ | público |

```bash
curl -k -u pmotiadm:pmotiadm https://localhost:9200
```

## 4. Verificação de IA / Agentic / LLM

```bash
A='pmotiadm:pmotiadm'; OS=https://localhost:9200

# Root agent registrado para o Assistant
AID=$(curl -sk -u $A $OS/_plugins/_ml/config/os_chat | jq -r .configuration.agent_id)

# Pergunta real (Agentic + LLM + tools)
curl -sk -u $A -H 'Content-Type: application/json' \
  -XPOST "$OS/_plugins/_ml/agents/$AID/_execute" \
  -d '{"parameters":{"question":"Liste os indices deste cluster."}}' \
  | jq -r '.inference_results[0].output[]|select(.name=="response")|.dataAsMap.response'

# Embeddings (neural search / RAG)
EMB=$(curl -sk -u $A -H 'Content-Type: application/json' "$OS/_plugins/_ml/models/_search" \
  -d '{"size":1,"query":{"bool":{"must":[{"term":{"algorithm":"TEXT_EMBEDDING"}},{"term":{"model_state":"DEPLOYED"}}]}}}' \
  | jq -r '.hits.hits[0]._id')
curl -sk -u $A -H 'Content-Type: application/json' \
  -XPOST "$OS/_plugins/_ml/_predict/text_embedding/$EMB" \
  -d '{"text_docs":["busca semantica"],"target_response":["sentence_embedding"]}' | jq '.inference_results[0].output[0].shape'
```

No Dashboards: ícone do **Assistant** (chat) e **Observability → Query Assist**.

### Detalhes que quebram silenciosamente

- **`CatIndexTool` não existe no OpenSearch 3.8.** O `_register` do agent
  aceita a tool, mas o `_execute` falha com `"Tool type not found"`. O
  `setup-ai.sh` monta a lista de tools a partir de `GET /_plugins/_ml/tools`,
  então só entra o que o cluster realmente expõe.
- **O agent conversacional não envia `parameters.messages`.** Ele monta o
  prompt (ReAct + histórico + tools) em `parameters.prompt`. Um connector com
  `"messages": ${parameters.messages}` registra e funciona no `_predict`
  manual, mas o `_execute` falha com `Invalid payload`. O connector monta o
  array `messages` a partir de `${parameters.prompt}`.
- **`.plugins-ml-*` são system indices protegidos** — nem `all_access` escreve
  neles, o que impede registrar o root agent em `.plugins-ml-config`. A stack
  liga `plugins.security.system_indices.permission.enabled=true` e cria a role
  `ml-config-writer` com `system:admin/system_index` em `.plugins-ml-*`.
  O escopo tem de ser `.plugins-ml-*`: restringir a `.plugins-ml-config` faz
  o próprio `_plugins/_ml/models/_search` retornar 403.

## 5. Operação

```bash
docker compose ps
docker compose logs -f provisioner   # o que foi provisionado
docker compose logs -f opensearch
docker compose down                  # volumes preservados
docker compose down -v               # APAGA volumes
```

Reexecutar o provisionamento (idempotente):

```bash
docker compose up -d --force-recreate provisioner
```

## 6. Enroll de agentes

**Linux**

```bash
curl -fsSL http://localhost/install-agent.sh | sudo sh
curl -fsSL http://localhost/install-agent.sh | sudo sh -s -- --uninstall
```

**Windows** (PowerShell como Admin)

```powershell
irm http://localhost/install-agent.ps1 | iex
& ([scriptblock]::Create((irm http://localhost/install-agent.ps1))) -Uninstall
```

Conferir ingestão:

```bash
curl -k -u pmotiadm:pmotiadm 'https://localhost:9200/_cat/indices/logs-*?v'
```

## 7. Logs limpos

```bash
docker compose logs | grep -E "\[WARN |\[ERROR|\[DEPRECATION|WARNING:|SLF4J"
```

**Regime permanente: zero linhas** em `opensearch-dashboards`, `provisioner` e
`enroll`. Depois do boot, `opensearch-node` também não emite mais nada.

### O que foi corrigido (e como)

| Ruído | Correção |
|---|---|
| `PluginSettings`/`StatsCollector`: `performance-analyzer.properties` e `plugin-stats-metadata` não existem | plugin **Performance Analyzer removido** no `scripts/opensearch-entrypoint.sh` (nada na stack usa) |
| `security_exception ... requestedTenant=__user__` e 403 em `/tenantinfo` | Dashboards passou a usar a conta de serviço **`kibanaserver`**; multitenancy desligada |
| `opensearch.requestHeadersWhitelist is deprecated` | renomeado para `requestHeadersAllowlist` |
| `Failed to find config ... os_summary` / `os_summary_with_log_pattern` | `setup-ai.sh` registra os **flow agents de resumo** do Assistant |
| `ListIndexTool: Failed to fetch index info for page: null` | tool fixada em `indices: ["*","-.*"]` — o `GET /_list/indices` dá 403 quando o alvo resolve índices de sistema |
| `UpdateConnector: N models are still using this connector` (HTTP 400) | `setup-ai.sh` faz undeploy dos modelos antes de atualizar o connector |
| `settings_exception: plugins.security_analytics.enable_detectors not recognized` | setting inexistente removido do `setup-features.sh` |
| `BackendRegistry: No 'Authorization' header` a cada 10s | healthcheck e sonda do provisioner passaram a **autenticar** |
| `insecure file permissions` (7×, certs demo) | `chmod 600/700` no entrypoint, depois do instalador demo |
| `node.max_local_storage_nodes` deprecated | linha removida do `opensearch.yml` gerado |
| `SQLPlugin: Master key is a required config` | `plugins.query.datasources.encryption.masterkey` definida |
| `sun.misc.Unsafe`, `Restricted methods`, `System::load` (JVM, 8 linhas) | `--enable-native-access=ALL-UNNAMED --sun-misc-unsafe-memory-access=allow` no `OPENSEARCH_JAVA_OPTS` |
| `AuditMessageRouter`, salt de compliance, `transport_enabled`, `HookRegistry`, `DanglingIndicesState`, `StreamTransportService`, `SecurityAnalyticsPlugin` | `logger.*=ERROR` no `docker-compose.yml` (via `-E`, no startup) — todos são FYI/corridas de boot que se resolvem sozinhas |

### O que sobra (15 linhas, só no boot)

Nenhuma recorre depois que o nó sobe e nenhuma afeta o funcionamento:

| Linha | Qtd | Por que fica |
|---|---|---|
| `WARNING: Using incubator modules: jdk.incubator.vector` | 1 | vem de `--add-modules=jdk.incubator.vector` no `jvm.options` da imagem; remover desliga a vetorização SIMD do Lucene |
| `[WARN][stderr] PanamaVectorizationProvider` / `Java vector incubator API enabled` | 2 | o Lucene imprime o mesmo aviso em stderr |
| `[WARN][stderr] SLF4J: ...` | 6 | plugins da imagem trazem `slf4j-api` (1.7 **e** 2.x) sem provider no mesmo classloader — empacotamento da imagem |
| `[ERROR] BackendRegistry: Security not initialized` | ~4 | sondas que chegam nos ~15 s em que o índice de segurança ainda sobe; normal em qualquer OpenSearch |
| `[WARN] Failed to load API tokens on node start` | 1 | corrida de boot (`state not recovered`); resolve sozinha |
| `[ERROR] MLModelManager: No controller is deployed` | 1 | o ML Commons loga em ERROR um estado **esperado** (modelo sem rate-limiter) |

As 9 primeiras só sairiam reconstruindo a imagem (`Dockerfile` próprio com
`jvm.options` editado e `slf4j-nop` nos plugins). As 6 últimas são transitórias.

## 8. Troubleshooting

**`Weak password` ao criar usuário** — use hash bcrypt em vez de senha em
texto puro; ver [Como a senha fraca é aplicada](#como-a-senha-fraca-é-aplicada).

**Provisioner sai com erro logo após o boot** — o ML Commons pode não estar
pronto. O `setup-ai.sh` já faz 10 tentativas na criação do connector; se ainda
falhar, `docker compose up -d --force-recreate provisioner`.

**`Nenhuma credencial conhecida autentica`** — o volume tem um índice de
segurança antigo com outra senha. `docker compose down -v` e suba de novo.

**Dashboards `unhealthy` mas a interface funciona** — o healthcheck usa
`OPENSEARCH_USERNAME`/`OPENSEARCH_PASSWORD` contra `/api/status`. Confira se
batem com o `.env`.

**LLM não responde** — verifique `LLM_API_KEY` no `.env`, conectividade HTTPS
ao OpenRouter e `docker compose logs opensearch | grep -i ml`.

**`Embedding model: <pendente>` / agente sem `VectorDBTool`** — no **primeiro**
boot com volume novo o ML Commons precisa baixar o modelo *e* o runtime nativo
do PyTorch/DJL (centenas de MB) e descompactá-lo; em host modesto isso passa
dos 600 s do timeout padrão e a task vira `FAILED: timeout after 600 seconds`.
O `setup-ai.sh` já sobe `plugins.ml_commons.ml_task_timeout_in_seconds` para
3600 e tenta duas vezes. Se ainda assim falhar:

```bash
docker compose up -d --force-recreate provisioner
docker compose logs -f opensearch-provisioner
```

A segunda execução é bem mais rápida — o que já baixou fica em cache no
container. Confira o estado da task com:

```bash
curl -k -u pmotiadm:pmotiadm 'https://localhost:9200/_plugins/_ml/tasks/<task_id>'
```

**Container encerra com Exit 137** — `vm.max_map_count` ou RAM insuficiente
(ver seção 1).
