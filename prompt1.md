
**Prompt:**

Você é um especialista em DevOps e containers Docker. Preciso que você forneça instruções completas e funcionais para provisionar a stack OpenSearch (incluindo OpenSearch e OpenSearch Dashboards) em um ambiente Docker, utilizando Docker Compose. Considere as seguintes diretrizes e requisitos:

**Contexto e requisitos:**
- Utilize as imagens oficiais do OpenSearch Project disponíveis no Docker Hub (opensearchproject/opensearch e opensearchproject/opensearch-dashboards), na versão estável mais recente (2.x).
- O provisionamento deve ser feito em um único host (modo single-node), ideal para desenvolvimento ou testes.
- Configure volumes persistentes para os dados do OpenSearch e para os dados dos Dashboards (se aplicável), garantindo que os dados não sejam perdidos ao reiniciar os containers.
- Ative a segurança básica do OpenSearch (plugins de segurança) com autenticação por senha. Defina uma senha forte para o usuário `admin` e para os usuários internos do Dashboards.
- Exponha as portas 9200 (API do OpenSearch) e 5601 (Dashboards) para acesso via host.
- Inclua a configuração necessária no sistema operacional host: `vm.max_map_count=262144` (via sysctl) e explique como aplicá-la de forma persistente.
- Defina limites de memória para os containers (ex.: `OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m`) e recomendações de recursos.
- Gere um arquivo `docker-compose.yml` completo, com serviços, redes, volumes, variáveis de ambiente e healthchecks.
- Inclua também instruções passo a passo para executar o compose, verificar o status, acessar as interfaces e testar a autenticação.


1. Pré-requisito no Sistema Operacional (Host)
O OpenSearch utiliza o Lucene para indexação e exige uma quantidade mínima de mapeamentos de memória virtual. Para evitar que o container falhe ao iniciar com erros de Out Of Memory, aumente o limite do Kernel Linux:

Aplicar temporariamente:

sudo sysctl -w vm.max_map_count=262144
Aplicar permanentemente:
Adicione a seguinte linha ao final do arquivo /etc/sysctl.conf:

vm.max_map_count=262144
Em seguida, recarregue as configurações do sistema com:

sudo sysctl -p
2. Arquivo docker-compose.yml
Crie uma pasta para o projeto e crie o arquivo docker-compose.yml com a seguinte estrutura:


3. Explicação da Configuração
discovery.type=single-node: Define que o nó funcionará isoladamente, sem buscar outros membros para formar um cluster. Ideal para desenvolvimento.
OPENSEARCH_JAVA_OPTS: Define o tamanho mínimo (-Xms) e máximo (-Xmx) da heap memory do Java para 512 MB.
OPENSEARCH_INITIAL_ADMIN_PASSWORD: A partir da versão 2.12+, é obrigatório definir uma senha forte para o usuário admin que cumpra os requisitos mínimos (maiúsculas, minúsculas, números e caracteres especiais).
ulimits.memlock: Permite ao container travar a memória para evitar o uso de swap, mantendo a performance do mecanismo de busca.
Volumes Persistentes: Garantem que os dados dos índices e as configurações do painel fiquem gravados no host mesmo que os containers sejam destruídos.
Healthcheck: Garante que o Dashboards só inicialize após o OpenSearch estar completamente pronto para aceitar conexões via HTTPS.

4. Executando e Testando a Stack
Passos para Iniciar:
No diretório onde está o arquivo docker-compose.yml, suba os containers:

docker compose up -d
Verifique o status dos containers:

docker compose ps
Testando a Autenticação no OpenSearch (API):
Utilize o curl ignorando o certificado SSL autoassinado (-k):

curl -k -u admin:SenhaForte123!@#Admin https://localhost:9200
Resposta esperada: Retorno de um objeto JSON contendo o nome do cluster, versão do OpenSearch e a mensagem "You Know, for Search".

Acessando o OpenSearch Dashboards:
Abra o navegador e acesse: http://localhost:5601

Na tela de login, insira as credenciais configuradas:
Usuário: admin
Senha: SenhaForte123!@#Admin

5. Resolução de Problemas Comuns
Container do OpenSearch encerra logo após iniciar (Exit 137 ou erro de memória):
Certifique-se de que o comando sysctl -w vm.max_map_count=262144 foi executado corretamente no host. Além disso, verifique se o Docker possui pelo menos 4 GB de RAM alocados nas configurações do seu sistema.

Erro Unauthorized ou falha ao logar no Dashboards:
Confira se a variável OPENSEARCH_INITIAL_ADMIN_PASSWORD no nó do OpenSearch é idêntica à OPENSEARCH_PASSWORD informada no serviço do Dashboards.

Conflito de Portas:
Se a porta 9200 ou 5601 já estiver sendo utilizada por outro serviço no seu computador, altere o mapeamento no docker-compose.yml no formato "PORTA_HOST:PORTA_CONTAINER" (exemplo: "9201:9200").

6. instalação
curl -fsSL https://raw.githubusercontent.com/josegoncalves2/repo-open-search/main/install.sh | bash


7. enroll
criar um setup personalizado para linux e windows:
exemplo:

## Instalar:
curl -fsSL http://192.168.1.73/install-agent.sh | sudo sh

## Desinstalar:
curl -fsSL http://192.168.1.73/install-agent.sh | sudo sh -s -- --uninstall

