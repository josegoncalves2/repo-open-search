# Stack OpenSearch — single-node, segurança ativa, IA + Agentic

Stack completa do OpenSearch **3.8.0** (versão `latest` estável em 2026-09-03)
com OpenSearch Dashboards, Fluent Bit, NGINX (enroll) e provisionamento
automático de **IA generativa / Agentic / LLM**.

## Recursos habilitados

| Categoria | Plugin / Recurso | Status |
|---|---|---|
| Core | OpenSearch + Dashboards 3.8.0 | ✅ |
| Segurança | TLS + autenticação por senha (admin + agent-ingest) | ✅ |
| Segurança | Security Analytics (detecção de ameaças) | ✅ |
| Observability | Index Patterns, Logs, Metrics, Traces | ✅ |
| Observability | Query Assistant (texto → PPL) | ✅ |
| Alertas | Alerting + Notifications | ✅ |
| ML | Anomaly Detection (AD) | ✅ |
| ML | ML Commons (modelos, pipelines, RAG) | ✅ |
| ML | k-NN (busca vetorial) | ✅ |
| IA generativa | OpenSearch Assistant (chat, text2viz, alertInsight, anomaly insights) | ✅ |
| Agentic | Root agent (ListIndex / Search / VectorDB / PPL / CatIndex) | ✅ |
| LLM | OpenRouter (modelo `minimax/minimax-m3:free`) via connector OpenAI-compatible | ✅ |
| Embeddings | Hugging Face sentence-transformers (384 dim) — local no cluster | ✅ |
| Index Management | ISM policies (rollover, retenção, snapshots) | ✅ |
| Agentes | Fluent Bit (Linux/Windows) enviando para `logs-<host>` | ✅ |
| Enroll | NGINX publicando scripts `install-agent.{sh,ps1}` | ✅ |

## Senha do admin

- **Pedida**: `pmotiadm` (radical)
- **Aplicada**: `PmoT1Adm@2026#SecureKey` (reforçada para passar no `zxcvbn`
  do OpenSearch 2.12+; sem caracteres de escape que quebrariam o YAML do Compose)

## Estrutura

| Arquivo | Função |
|---|---|
| `docker-compose.yml` | Stack: OpenSearch + Dashboards + enroll |
| `.env` | Versão, senhas, heap, limites de memória, portas, LLM |
| `.env.agent` | Credenciais reais do `agent-ingest` (NÃO vai pro Git) |
| `.env.agent.example` | Modelo das credenciais de ingestão |
| `config/opensearch.yml` | Config principal do nó (todos os plugins ativos) |
| `config/opensearch_dashboards.yml` | Config Dashboards (Assistant + dashboards de ML) |
| `install.sh` | Provisionamento completo em host novo |
| `agent/install-agent.sh` | Enroll Linux (Fluent Bit) |
| `agent/install-agent.ps1` | Enroll Windows (Fluent Bit) |
| `scripts/setup-agent-user.sh` | Cria usuário de ingestão (logs-*) |
| `scripts/setup-features.sh` | Ativa plugins via cluster settings |
| `scripts/setup-ai.sh` | Provisiona connector, modelos e root agent |

## 1. Pré-requisito do host

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
sudo sysctl --system
```

Recursos: **≥ 4 GB RAM** e 2 vCPU. Heap da JVM em 1.5 GB (`OPENSEARCH_JAVA_OPTS`).

## 2. Subir a stack

```bash
cd /opt/projetos/openstack
docker compose up -d
docker compose ps        # todos "healthy"
```

Instalação em host novo:

```bash
curl -fsSL https://raw.githubusercontent.com/josegoncalves2/repo-open-search/main/install.sh | bash
```

## 3. Acesso

| Serviço | Endereço | Credenciais |
|---|---|---|
| Dashboards | http://localhost:5601 | `admin` / `PmoT1Adm@2026#SecureKey` |
| API OpenSearch | https://localhost:9200 | idem (TLS autoassinado → `curl -k`) |
| Enroll | http://localhost/ | público |

```bash
curl -k -u admin:'PmoT1Adm@2026#SecureKey' https://localhost:9200
```

## 4. Verificação de IA / Agentic / LLM

```bash
# Connector criado
curl -k -u admin:'PmoT1Adm@2026#SecureKey' \
  https://localhost:9200/_plugins/_ml/connectors/_search | jq '.hits.hits[]._name'

# Modelos registrados
curl -k -u admin:'PmoT1Adm@2026#SecureKey' \
  https://localhost:9200/_plugins/_ml/models/_search | jq '.hits.hits[]._name'

# Root agent (OpenSearch Assistant)
curl -k -u admin:'PmoT1Adm@2026#SecureKey' \
  https://localhost:9200/_plugins/_ml/agents/_search | jq '.hits.hits[]._name'

# Chat de teste
curl -k -u admin:'PmoT1Adm@2026#SecureKey' \
  -H 'Content-Type: application/json' \
  -XPOST 'https://localhost:9200/_plugins/_ml/agents/<agent_id>/_execute' \
  -d '{"parameters":{"question":"Liste os índices do cluster"}}'
```

No Dashboards: **Stack Management → Plugins → Assistant** — o campo "Root
agent" aponta para o ID retornado acima.

## 5. Operação

```bash
docker compose ps
docker compose logs -f opensearch
docker compose restart opensearch-dashboards
docker compose down      # volumes preservados
docker compose down -v   # APAGA volumes
```

Reativar features / IA manualmente:

```bash
cd /opt/projetos/openstack
OS_ADMIN_PASS='PmoT1Adm@2026#SecureKey' bash scripts/setup-features.sh
bash scripts/setup-ai.sh   # usa .env
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
curl -k -u admin:'PmoT1Adm@2026#SecureKey' \
  'https://localhost:9200/_cat/indices/logs-*?v'
```

## 7. Troubleshooting

**`OPENSEARCH_INITIAL_ADMIN_PASSWORD` inválida** — tem que ter ≥ 8 chars,
maiúscula, minúscula, número e especial, **e** passar no `zxcvbn` (a
biblioteca bloqueia padrões como `pmotiadm`, datas, sequências, etc.).

**Dashboards fica `unhealthy` mas a interface funciona** — o healthcheck manda
`/api/status` com `-u admin:$OPENSEARCH_PASSWORD`. Verifique se a senha bate.

**Plugins não aparecem ativos** — rode `scripts/setup-features.sh` (idempotente).
Como a config está em `opensearch.yml` montado via volume, basta um
`docker compose restart opensearch`.

**LLM não responde** — verifique `LLM_API_KEY` no `.env`, conectividade HTTPS
ao OpenRouter e logs do OpenSearch (`docker compose logs opensearch | grep -i ml`).