# Fluid

[English](README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | Português | [العربية](README.ar.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

Duas coisas que o seu agente de código não faz por você, resolvidas enquanto você está longe do teclado.

- **Janela sempre aberta** — uma nova janela de uso é aberta assim que a anterior é reiniciada, mesmo sem ninguém trabalhando, então quando você volta já há uma cota cheia em andamento.
- **Aviso** — quando isso deixa de funcionar, ele avisa: Bark, ntfy, e-mail, ou qualquer outro canal que você queira ligar.

Retomar uma sessão depois de um limite de uso é algo que os agentes agora fazem sozinhos; quando isso não acontece, o Fluid faz por eles (veja Retomada abaixo).

## Agentes

Claude Code, Codex e Antigravity medem uma assinatura do mesmo jeito: uma janela curta que começa no seu primeiro pedido, e uma mais longa por cima. O Fluid mantém aqueles que você tiver instalado.

| Agente | De onde vêm os limites | Mudanças na configuração dele |
|---|---|---|
| Claude Code | a status line dele, a cada atualização | uma entrada de status line, um hook |
| Codex | os logs de sessão dele, lidos quando preciso | nenhuma |
| Antigravity | a status line dele, a cada atualização | uma entrada de status line |

Cada agente tem a própria janela, o próprio agendamento e os próprios avisos; nada é compartilhado. Adicionar outro é um arquivo só — veja [docs/PROVIDERS.md](docs/PROVIDERS.md). A interface declarar o tipo de medição tem um motivo: no Kimi Code a janela curta limita a taxa de pedidos em vez de medir uma cota, e o Grok Build tem um único pote semanal sem janela curta — nesses casos não haveria janela nenhuma para manter aberta.

## Para que serve

**Quando a janela abre decide quando ela termina.** Uma janela começa no seu primeiro pedido, não numa hora fixa. Com uma janela de cinco horas: comece a trabalhar às 9h e ela vai das 9h às 14h; esgote a cota às 11h e você fica travado até as 14h. Se em vez disso um pedido mínimo tivesse aberto a janela às 6h, ela expiraria às 11h — exatamente quando você fica sem nada — com uma cota nova já esperando. Com uma janela sempre aberta, já há uma em andamento quando você começa: o que resta dela é cota que de outro modo se perderia, e uma nova chega em no máximo uma janela, geralmente bem antes.

**Um dia de trabalho cabe mais janelas quando elas começam cedo.** Comece às 9h e as janelas vão das 9h às 14h e das 14h às 19h: duas até você encerrar o dia. Se em vez disso uma tivesse aberto às 6h, o dia seria coberto por 6h-11h, 11h-16h e 16h-21h — três, nas mesmas horas de trabalho. É para isso que serve o horário fixo, mais abaixo.

**Saber quando ele parou de ajudar.** Manter janelas abertas só funciona enquanto um login for válido e o agendador estiver rodando; se um dos dois parar, nada acontece. O Fluid percebe qualquer um dos casos e avisa, em vez de falhar em silêncio o fim de semana inteiro.

## Requisitos

Linux ou macOS, com `jq` e pelo menos um entre `claude`, `codex` e `agy`. No Linux, as execuções são agendadas com `at`, então o `atd` precisa estar rodando; no macOS quem cuida disso é o launchd, sem nada para configurar. A Retomada precisa de `tmux`. No Windows, rode o Claude Code dentro do WSL com o systemd ativado, para que o atd possa iniciar.

```bash
sudo systemctl enable --now atd   # Linux
brew install jq tmux              # macOS
```

## Instalação

```bash
npx fluid-agents
```

Ou a partir de um clone:

```bash
git clone https://github.com/MrJasonZhou/fluid.git
cd fluid
bash install-fluid.sh
```

Ou como plugin do Claude Code, cujo instalador você roda depois de dentro do próprio Claude Code:

```
/plugin install fluid --marketplace MrJasonZhou/fluid
/fluid:install
```

Ele já traz o hook da Retomada, então o instalador não o põe nas suas configurações, e adiciona `/fluid:status`, `/fluid:anchor` e `/fluid:uninstall`.

Para cada agente que tem status line, o instalador envolve a que você já tinha, que continua aparecendo exatamente como antes; é, junto com um hook para o Claude Code (veja Retomada), a única mudança nas configurações daquele agente, e todo arquivo de configuração é salvo antes. O Codex não precisa de configuração alguma. Rodar o instalador de novo é uma atualização limpa, não uma segunda cópia, e preserva para cada agente a próxima execução agendada, o estado dela e o seu notificador.

## Uso

No dia a dia não há nada para executar — ele trabalha sozinho. Quando quiser olhar:

```bash
~/.fluid/fluid.sh status    # por agente: janela, agendamento, falhas
~/.fluid/fluid.sh providers # quais agentes estão instalados
tail -f ~/.fluid/fluid.log  # o que ele andou fazendo
```

## Abrir em um horário fixo

Por padrão, uma janela abre assim que a anterior é reiniciada, então a cadeia segue o horário em que você esgotou a cota da última vez. Para fixá-la em um horário do dia:

```bash
~/.fluid/fluid.sh anchor 06:00   # abrir às 06h
~/.fluid/fluid.sh anchor         # mostrar a configuração
~/.fluid/fluid.sh anchor off     # voltar a abrir assim que possível
```

Uma janela que passaria por cima desse horário espera por ele: a prevista para 03h cobriria 03h-08h e engoliria as 06h, então ela abre às 06h. As horas antes ficam sem janela — se você trabalhar nesse período, seu próprio primeiro pedido abre uma normalmente. A configuração vale para todos os agentes.

## O modelo usado no warm-up

Abrir uma janela custa um pedido, então o Fluid o mantém o menor possível: o modelo mais barato do agente, sem ferramentas e sem escrever nada no histórico. Modelos vêm e vão, e quando um agente deixa de conhecer o que está em uso ele avisa claramente — o Fluid passa então para o modelo padrão do próprio agente e conta isso a você uma vez, em vez de falhar janela após janela até alguém ler o log.

```bash
~/.fluid/fluid.sh model                 # com que cada agente é aquecido
~/.fluid/fluid.sh model claude sonnet   # escolher um você mesmo
~/.fluid/fluid.sh model claude auto     # voltar ao mais barato
```

## Retomada

O Claude Code retoma uma sessão sozinho quando um limite de uso é zerado ("Continue automatically at usage limit" em `/config`). Às vezes isso não acontece — uma tecla apertada sem querer cancelou a contagem regressiva, ou ela nunca começou — e a sessão fica parada até você perceber. O Fluid é a rede de segurança: anota cada sessão que para num limite e, três minutos depois de zerar, olha de novo. Se ela ainda estiver parada, digita `continue` no pane tmux dela.

Fora isso, não se mete. Nada é digitado se o Claude Code ou você já continuaram, se você cancelou a contagem com Esc, ou se o pane agora roda outra coisa; tenta no máximo duas vezes e depois avisa você. Uma sessão fora do tmux não tem onde receber texto, então só fica registrada no log.

## Avisos

O Fluid fica quieto enquanto nada precisa de você, e informa seis coisas:

| | |
|---|---|
| **Desconectado** | O login de um agente expirou; para ele nada pode ser aberto até você entrar de novo |
| **Falhas repetidas** | Vários warm-ups seguidos falharam para um agente |
| **Agendador parado** | Uma execução agendada está muito atrasada, então nenhuma janela está sendo mantida aberta; geralmente o `atd` não está rodando |
| **De volta ao normal** | Ele se recuperou de qualquer um dos problemas acima |
| **Modelo de warm-up sumiu** | O modelo com que um agente era aquecido não existe mais, então a partir de agora usa-se o padrão dele |
| **Não retomada** | Uma sessão continuava parada depois que o limite de uso zerou, e digitar `continue` também não a fez andar |

Cada um é anunciado uma única vez por agente, não a cada nova tentativa: um problema durante a noite custa uma só mensagem. Uma falha que se resolve sozinha não custa nenhuma: que um agente está desconectado só é avisado depois que uma tentativa posterior também falha. Os limites de uso em si nunca são anunciados: são rotina, e os agentes, ou o Fluid por trás deles, retomam depois deles.

Para escolher como receber o aviso, copie um dos exemplos e preencha sua chave ou servidor:

```bash
cd ~/.fluid
cp notify/bark.sh.sample notify.sh      # ou ntfy.sh.sample, email.sh.sample
chmod +x notify.sh                      # use 700 no de e-mail, ele guarda uma senha
$EDITOR notify.sh
./fluid.sh notify-test            # confirme que chega até você
```

O notificador é apenas um executável que recebe `CP_EVENT`, `CP_MESSAGE` e `CP_HOST`, então Telegram, Slack, um webhook ou `mail` são questão de reescrever uma linha. Sua cópia sobrevive a reinstalações.

## Arquivos

Está tudo em `~/.fluid/`:

| | |
|---|---|
| `fluid.sh` | O script em si |
| `providers/` | Um arquivo por agente |
| `state/<agente>/` | Janela, agendamento e estado dos avisos daquele agente |
| `notify.sh` | Seu notificador, depois de configurado |
| `notify/` | Exemplos para copiar |
| `anchor` | O horário em que as janelas abrem, se você definir um |
| `fluid.log` | O que ele andou fazendo |

## Desinstalação

```bash
npx fluid-agents uninstall
```

Ou a partir de um clone: `bash install-fluid.sh uninstall`.

Ela edita as configurações de cada agente no próprio lugar e retira apenas o que o Fluid adicionou: sua status line volta, e todas as outras configurações ficam exatamente como estão — inclusive as adicionadas depois da instalação. As tarefas agendadas são canceladas e `~/.fluid/` é apagado, junto com o seu `notify.sh`. Rodar de novo não causa nenhum dano.

Se depois outro programa envolveu alguma status line por fora do Fluid, desinstalar não o quebra. Fica para trás um pequeno script de repasse para que esse programa continue funcionando, e o desinstalador avisa; rode de novo quando nada mais precisar dele. Uma atualização na mesma situação permanece dentro da cadeia desse programa em vez de envolvê-lo por sua vez.

Uma cópia de cada arquivo de configuração de logo antes da desinstalação fica ao lado dele, assim como as cópias feitas na instalação (as cinco mais recentes), caso você precise voltar atrás à mão.

## Licença

GPL-3.0-or-later. Veja [LICENSE](LICENSE).
