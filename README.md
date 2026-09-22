# Apple Lembretes ↔ Google Tasks

Ponte local bidirecional, segura por padrão. A execução normal é uma simulação (`dry-run`); qualquer gravação exige explicitamente `--apply --confirm APPLY`.

## Aplicativo para macOS

`Reminders Sync.app` é um aplicativo nativo em SwiftUI que abre na barra de menus ao iniciar a sessão do macOS. Clique no símbolo de calendário e lista no alto da tela para abrir o painel. Ele permite:

- conferir se o serviço está funcionando;
- ver a última e a próxima execução;
- consultar o histórico recente e mensagens de erro;
- pausar e retomar a sincronização sem fechar o painel;
- solicitar uma sincronização imediata.

O aplicativo fica fora do Dock. Ele lê apenas os arquivos locais de estado e histórico, não abre portas de rede, não usa navegador e não recebe as credenciais do Google. Encerrar o aplicativo pelo menu lateral não interrompe a sincronização em segundo plano.

## Proteções

- Tarefas Google sem a marca `[apple-reminders-bridge:v2]` nunca são alteradas nem copiadas para o Apple.
- Tarefas antigas com a marca `v1` são migradas no lugar, sem criar duplicatas.
- A associação usa o UUID do Apple Lembretes, não o título.
- Exclusões não são propagadas automaticamente.
- O estado e as credenciais locais recebem permissão `600`.
- Lembretes com horário preservam a hora original nas notas. O Google Tasks mantém apenas a data.
- Conclusão e reabertura são propagadas nos dois sentidos.
- Se Apple e Google mudarem antes da próxima execução, a alteração mais recente vence.

## Lembretes recorrentes

O Apple Lembretes é a fonte da regra de recorrência. Como a API do Google Tasks não oferece um campo de recorrência, a ponte representa cada ocorrência como uma tarefa Google separada:

- ao concluir a ocorrência no Apple, a tarefa Google correspondente é concluída e a próxima ocorrência aberta pelo Apple vira uma nova tarefa Google;
- ao concluir a ocorrência atual no Google, a mesma ocorrência é concluída no Apple; o Apple gera a seguinte e ela aparece no Google na próxima sincronização;
- ocorrências Google concluídas permanecem no histórico;
- ocorrências antigas do Apple que nunca foram sincronizadas não são importadas retroativamente;
- alterações de título, data e horário da ocorrência atual continuam bidirecionais. O horário fica preservado nas notas porque a API do Google Tasks aceita apenas a data.

A associação de uma série usa a lista e a data de criação fornecidas pelo EventKit. Cada ocorrência continua usando seu próprio UUID do Apple, evitando confundir tarefas iguais ou criar cópias ao atualizar uma data.

## Simulação

```bash
python bridge.py \
  --apple-json /caminho/open-reminders.json \
  --credentials /caminho/credentials.json \
  --token /caminho/token.json \
  --state /caminho/state.json \
  --plan-json /caminho/plan.json
```

## Aplicação

Revise primeiro o plano. Para efetivar somente as ações exibidas:

```bash
python bridge.py ... --apply --confirm APPLY
```

Para leitura e escrita ao vivo no Apple Lembretes, substitua `--apple-json` por `--remindctl /caminho/remindctl` e execute em um processo que possua permissão para acessar Lembretes.

## Automação

O intervalo padrão é de cinco minutos. `launchd.plist.template` contém a configuração do serviço; `run-sync.sh` executa uma sincronização bidirecional protegida e grava logs locais.

Pré-requisitos:

- macOS com Apple Lembretes e `remindctl` autorizado;
- Python 3.10 ou superior;
- Google Tasks API ativada;
- credencial OAuth para aplicativo de computador e um `token.json` autorizado.

Coloque `credentials.json` e `token.json` ao lado do instalador ou informe seus caminhos:

```bash
BRIDGE_PYTHON=/caminho/python3 \
BRIDGE_REMINDCTL=/caminho/remindctl \
BRIDGE_CREDENTIALS=/caminho/credentials.json \
BRIDGE_TOKEN=/caminho/token.json \
BRIDGE_STATE=/caminho/state.json \
./install.command
```

O instalador copia o serviço para `~/Library/Application Support/AppleGoogleRemindersBridge`, protege credenciais e estado, registra o agente de sincronização, compila o aplicativo nativo e o instala em `~/Applications/Reminders Sync.app`. Um segundo agente abre apenas o painel da barra de menus no login; encerrar o aplicativo não encerra o sincronizador.

O aplicativo também pode ser recompilado e instalado separadamente:

```bash
./build-macos-app.command
```

Para alterar o intervalo, edite `StartInterval` no template antes da instalação. O valor é expresso em segundos.

## Testes

```bash
python test_bridge.py -v
```

Os testes cobrem criação, conclusão e reabertura nos dois sentidos, migração sem duplicatas, resolução de alterações concorrentes e avanço de ocorrências diárias.

## Privacidade

Credenciais, tokens, estado, logs e ambientes virtuais são ignorados pelo Git. Nunca publique esses arquivos nem remova as regras correspondentes de `.gitignore`.
