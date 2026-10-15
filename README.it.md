# Fluid

[English](README.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | Italiano | [Português](README.pt.md) | [العربية](README.ar.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

Due cose che il tuo agente di codice non fa al posto tuo, sbrigate mentre sei lontano dalla tastiera.

- **Finestra sempre aperta** — appena l'ultima finestra d'uso si azzera se ne apre una nuova, anche se nessuno sta lavorando: quando torni, una quota piena è già in corso.
- **Avviso** — quando questo smette di funzionare te lo dice: Bark, ntfy, email o qualunque altro canale tu voglia collegare.

Riprendere una sessione dopo un limite d'uso ora lo fanno gli agenti stessi; quando non succede, ci pensa Fluid al posto loro (vedi Ripresa più sotto).

## Agenti

Claude Code, Codex e Antigravity misurano un abbonamento allo stesso modo: una finestra breve che parte dalla tua prima richiesta, e una più lunga sopra. Fluid tiene aperti quelli che hai installato.

| Agente | Da dove vengono i suoi limiti | Modifiche alla sua configurazione |
|---|---|---|
| Claude Code | la sua status line, a ogni aggiornamento | una voce di status line, un hook |
| Codex | i suoi log di sessione, letti quando serve | nessuna |
| Antigravity | la sua status line, a ogni aggiornamento | una voce di status line |

Ogni agente ha la propria finestra, la propria pianificazione e i propri avvisi; nulla viene condiviso. Aggiungerne un altro è un file solo — vedi [docs/PROVIDERS.md](docs/PROVIDERS.md). Che l'interfaccia dichiari il tipo di misurazione ha una ragione: in Kimi Code la finestra breve limita la frequenza delle richieste invece di misurare una quota, e Grok Build ha un unico serbatoio settimanale senza finestra breve — in quei casi non ci sarebbe alcuna finestra da tenere aperta.

## A cosa serve

**Quando si apre la finestra decide quando finisce.** Una finestra parte dalla tua prima richiesta, non a un'ora fissa. Con una finestra da cinque ore: inizi a lavorare alle 9:00 e va dalle 9:00 alle 14:00; esaurisci la quota alle 11:00 e resti fuori fino alle 14:00. Se invece una minuscola richiesta avesse aperto la finestra alle 6:00, questa scadrebbe alle 11:00 — esattamente quando rimani a secco — con una quota nuova già pronta. Con una finestra sempre attiva, quando inizi ce n'è già una in corso: ciò che ne resta è quota che altrimenti andrebbe sprecata, e una nuova arriva al massimo tra una finestra, di solito molto prima.

**Una giornata di lavoro contiene più finestre se cominciano presto.** Inizi alle 9:00 e le finestre vanno dalle 9:00 alle 14:00 e dalle 14:00 alle 19:00: due prima di staccare. Se invece una si fosse aperta alle 6:00, la giornata sarebbe coperta da 6:00-11:00, 11:00-16:00 e 16:00-21:00 — tre, a parità di ore alla scrivania. L'ora fissa più sotto serve proprio a questo.

**Sapere quando ha smesso di aiutarti.** Tenere aperte le finestre funziona solo finché un accesso è valido e il pianificatore è attivo; se uno dei due si ferma, non succede più nulla. Fluid riconosce entrambi i casi e te lo dice, invece di fallire in silenzio per tutto il fine settimana.

## Requisiti

Linux o macOS, con `jq` e almeno uno fra `claude`, `codex` e `agy`. Su Linux le esecuzioni sono pianificate con `at`, quindi `atd` deve essere attivo; su macOS se ne occupa launchd, senza nulla da configurare. Per la Ripresa serve `tmux`. Su Windows, esegui Claude Code dentro WSL con systemd attivo, così che atd possa partire.

```bash
sudo systemctl enable --now atd   # Linux
brew install jq tmux              # macOS
```

## Installazione

```bash
npx fluid-agents
```

Oppure da un clone:

```bash
git clone https://github.com/MrJasonZhou/fluid.git
cd fluid
bash install-fluid.sh
```

Oppure come plugin di Claude Code, di cui poi avvii l'installatore da dentro Claude Code:

```
/plugin install fluid --marketplace MrJasonZhou/fluid
/fluid:install
```

Porta con sé l'hook della Ripresa, quindi l'installatore non lo aggiunge alle tue impostazioni, e aggiunge `/fluid:status`, `/fluid:anchor` e `/fluid:uninstall`.

Per ogni agente dotato di status line, l'installatore avvolge quella che avevi già, che si vede esattamente come prima; è, insieme a un hook per Claude Code (vedi Ripresa), l'unica modifica alle impostazioni di quell'agente, e ogni file di impostazioni viene salvato prima. Codex non richiede alcuna configurazione. Rieseguire l'installatore è un aggiornamento pulito anziché una seconda copia, e conserva per ogni agente la prossima esecuzione pianificata, il suo stato e il tuo notificatore.

## Uso

Nel quotidiano non c'è nulla da eseguire — lavora da solo. Quando vuoi dare un'occhiata:

```bash
~/.fluid/fluid.sh status    # per agente: finestra, pianificazione, fallimenti
~/.fluid/fluid.sh providers # quali agenti sono installati
tail -f ~/.fluid/fluid.log  # cosa ha fatto
```

## Aprire a un'ora fissa

Per impostazione predefinita una finestra si apre appena la precedente si azzera, quindi la catena segue l'ora in cui hai finito la quota l'ultima volta. Per fissarla a un'ora del giorno:

```bash
~/.fluid/fluid.sh anchor 06:00   # apri alle 06:00
~/.fluid/fluid.sh anchor         # mostra l'impostazione
~/.fluid/fluid.sh anchor off     # torna ad aprire appena possibile
```

Una finestra che passerebbe sopra quell'ora la aspetta: quella prevista alle 03:00 coprirebbe 03:00-08:00 inghiottendo le 06:00, quindi si apre alle 06:00. Le ore prima restano senza finestra — se lavori in quel momento, la tua prima richiesta ne apre una come sempre. L'impostazione vale per tutti gli agenti.

## Il modello usato per il warm-up

Aprire una finestra costa una richiesta, quindi Fluid la tiene più piccola possibile: il modello più economico dell'agente, senza strumenti e senza scrivere nulla nella cronologia. I modelli vanno e vengono, e quando un agente non conosce più quello in uso lo dice chiaramente — Fluid passa allora al modello predefinito dell'agente e te lo segnala una volta, invece di fallire finestra dopo finestra finché qualcuno non legge il log.

```bash
~/.fluid/fluid.sh model                 # con che cosa si scalda ogni agente
~/.fluid/fluid.sh model claude sonnet   # sceglierne uno tu
~/.fluid/fluid.sh model claude auto     # tornare al più economico
```

## Ripresa

Claude Code riprende una sessione da solo quando un limite d'uso si azzera ("Continue automatically at usage limit" in `/config`). A volte non lo fa — un tasto premuto per sbaglio ha annullato il conto alla rovescia, oppure non è mai partito — e la sessione resta ferma finché non te ne accorgi. Fluid fa da rete: annota ogni sessione che si ferma su un limite, e tre minuti dopo l'azzeramento la ricontrolla. Se è ancora ferma, scrive `continue` nel suo pane tmux.

Per il resto non si intromette. Non viene scritto nulla se Claude Code o tu avete già ripreso, se hai annullato il conto alla rovescia con Esc, o se nel pane ora gira altro; ci prova al massimo due volte, poi te lo dice. Una sessione fuori da tmux non ha dove ricevere testo, quindi viene solo registrata nel log.

## Avvisi

Fluid resta in silenzio finché non serve il tuo intervento, e segnala sei cose:

| | |
|---|---|
| **Disconnesso** | L'accesso di un agente è scaduto: per lui non si può aprire nulla finché non rientri |
| **Fallimenti ripetuti** | Diversi warm-up di fila sono falliti per un agente |
| **Pianificatore fermo** | Un'esecuzione pianificata è molto in ritardo, quindi nessuna finestra viene tenuta aperta; di solito `atd` non è in esecuzione |
| **Tornato normale** | Si è ripreso da uno dei problemi sopra |
| **Modello di warm-up sparito** | Il modello con cui un agente veniva scaldato non esiste più, quindi d'ora in poi si usa il suo predefinito |
| **Non ripresa** | Una sessione era ancora ferma dopo l'azzeramento del suo limite d'uso, e nemmeno scrivere `continue` l'ha fatta ripartire |

Ogni cosa viene segnalata una volta sola per agente, non a ogni nuovo tentativo: un problema notturno ti costa un unico messaggio. Un guasto che si risolve da sé non te ne costa nessuno: che un agente sia disconnesso viene segnalato solo dopo che è fallito anche un tentativo successivo. I limiti d'uso in sé non vengono mai annunciati: sono ordinaria amministrazione, e gli agenti, o Fluid dietro di loro, riprendono dopo di essi.

Per scegliere come riceverlo, copia uno degli esempi e inserisci la tua chiave o il tuo server:

```bash
cd ~/.fluid
cp notify/bark.sh.sample notify.sh      # oppure ntfy.sh.sample, email.sh.sample
chmod +x notify.sh                      # 700 per quello email, contiene una password
$EDITOR notify.sh
./fluid.sh notify-test            # verifica che ti arrivi
```

Il notificatore è solo un eseguibile che riceve `CP_EVENT`, `CP_MESSAGE` e `CP_HOST`, quindi Telegram, Slack, un webhook o `mail` si riducono a riscrivere una riga. La tua copia sopravvive alle reinstallazioni.

## File

Sta tutto sotto `~/.fluid/`:

| | |
|---|---|
| `fluid.sh` | Lo script stesso |
| `providers/` | Un file per agente |
| `state/<agente>/` | Finestra, pianificazione e stato degli avvisi di quell'agente |
| `notify.sh` | Il tuo notificatore, una volta configurato |
| `notify/` | Esempi da copiare |
| `anchor` | L'ora a cui si aprono le finestre, se ne hai impostata una |
| `fluid.log` | Cosa ha fatto |

## Disinstallazione

```bash
npx fluid-agents uninstall
```

Oppure da un clone: `bash install-fluid.sh uninstall`.

Modifica sul posto le impostazioni di ogni agente e toglie solo ciò che Fluid ha aggiunto: la tua status line torna com'era, e ogni altra impostazione resta esattamente com'è — compresi gli elementi aggiunti dopo l'installazione. I job pianificati vengono annullati e `~/.fluid/` viene eliminato, insieme al tuo `notify.sh`. Eseguirla una seconda volta non fa alcun danno.

Se nel frattempo un altro programma ha avvolto una status line attorno a Fluid, la disinstallazione non lo rompe. Resta un piccolo script di passaggio perché quel programma continui a funzionare, e il disinstallatore te lo segnala; eseguilo di nuovo quando non serve più a nulla. Un aggiornamento nella stessa situazione resta dentro la catena di quel programma invece di avvolgerlo a sua volta.

Una copia di ogni file di impostazioni di subito prima della disinstallazione resta lì accanto, così come le copie fatte all'installazione (le cinque più recenti), nel caso ti serva mai tornare indietro a mano.

## Licenza

GPL-3.0-or-later. Vedi [LICENSE](LICENSE).
