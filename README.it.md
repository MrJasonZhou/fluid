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
| Claude Code | il modulo di hook del plugin Fluid, quando l'uso cambia | nessuna |
| Codex | i suoi log di sessione, letti quando serve | nessuna |
| Antigravity | la sua status line, a ogni aggiornamento | una voce di status line |

Ogni agente ha la propria finestra, la propria pianificazione e i propri avvisi; nulla viene condiviso. Aggiungerne un altro è un file solo — vedi [docs/PROVIDERS.md](docs/PROVIDERS.md). Che l'interfaccia dichiari il tipo di misurazione ha una ragione: in Kimi Code la finestra breve limita la frequenza delle richieste invece di misurare una quota, e Grok Build ha un unico serbatoio settimanale senza finestra breve — in quei casi non ci sarebbe alcuna finestra da tenere aperta.

## A cosa serve

**Quando si apre la finestra decide quando finisce.** Una finestra parte dalla tua prima richiesta, non a un'ora fissa. Con una finestra da cinque ore: inizi a lavorare alle 9:00 e va dalle 9:00 alle 14:00; esaurisci la quota alle 11:00 e resti fuori fino alle 14:00. Se invece una minuscola richiesta avesse aperto la finestra alle 6:00, questa scadrebbe alle 11:00 — esattamente quando rimani a secco — con una quota nuova già pronta. Con una finestra sempre attiva, quando inizi ce n'è già una in corso: ciò che ne resta è quota che altrimenti andrebbe sprecata, e una nuova arriva al massimo tra una finestra, di solito molto prima.

**Una giornata di lavoro contiene più finestre se cominciano presto.** Inizi alle 9:00 e le finestre vanno dalle 9:00 alle 14:00 e dalle 14:00 alle 19:00: due prima di staccare. Se invece una si fosse aperta alle 6:00, la giornata sarebbe coperta da 6:00-11:00, 11:00-16:00 e 16:00-21:00 — tre, a parità di ore alla scrivania. L'ora fissa più sotto serve proprio a questo.

**Sapere quando ha smesso di aiutarti.** Tenere aperte le finestre funziona solo finché un accesso è valido e il pianificatore è attivo; se uno dei due si ferma, non succede più nulla. Fluid riconosce entrambi i casi e te lo dice, invece di fallire in silenzio per tutto il fine settimana.

## Requisiti

Linux o macOS, con `jq` e almeno uno fra `claude`, `codex` e `agy`. Per Claude Code, installa Fluid come plugin (più sotto): le sue letture e la Ripresa arrivano dal modulo di hook del plugin. Su Linux le esecuzioni sono pianificate con `at`, quindi `atd` deve essere attivo; su macOS se ne occupa launchd, senza nulla da configurare. Su Windows, esegui Claude Code dentro WSL con systemd attivo, così atd può avviarsi.

```bash
sudo systemctl enable --now atd   # Linux
brew install jq                   # macOS
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

Aggiunge `/fluid:status`, `/fluid:anchor` e `/fluid:uninstall`, e un modulo di hook che gira dentro Claude Code: passa a Fluid le letture dell'uso e riprende una sessione ferma (vedi Ripresa), senza toccare le impostazioni di Claude Code. I moduli di hook sono ancora in fase di distribuzione agli account. Dove il modulo non si carica, o senza il plugin, Fluid non riceve letture da Claude Code: non viene pianificato nulla finché non arriva una prima lettura, e dopo la catena procede solo in base agli orari di azzeramento stimati. L'installatore dice quando il modulo non si è caricato. `/fluid:status` mostra da dove arrivano le letture.

Per Antigravity, l'installatore avvolge la status line che avevi già, che continua a essere mostrata esattamente come prima; è l'unica modifica alle sue impostazioni, e ogni file di impostazioni viene prima salvato. Codex e Claude Code non richiedono alcuna configurazione. Rieseguire l'installatore è un aggiornamento pulito e non una seconda installazione, e conserva per ogni agente la prossima esecuzione pianificata, il suo stato e il tuo notificatore. Le versioni precedenti alla 0.3.0 avvolgevano anche la status line di Claude Code e aggiungevano un hook alle sue impostazioni: disinstalla una volta (più sotto) prima di installare il plugin, ed entrambi vengono tolti.

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

Aprire una finestra costa una richiesta, quindi Fluid la tiene piccola quanto la CLI di ciascun agente consente: un breve prompt, eseguito da `/`. Claude Code usa il suo modello più economico, senza strumenti e senza scrivere nulla nella cronologia; Codex gira in sola lettura e non conserva file di sessione; Antigravity gira come farebbe per te. I modelli vanno e vengono, e quando un agente non conosce più quello in uso lo dice chiaramente — Fluid passa allora al modello predefinito dell'agente e te lo segnala una volta, invece di fallire finestra dopo finestra finché qualcuno non legge il log.

```bash
~/.fluid/fluid.sh model                 # con che cosa si scalda ogni agente
~/.fluid/fluid.sh model claude sonnet   # sceglierne uno tu
~/.fluid/fluid.sh model claude auto     # tornare al più economico
```

## Ripresa

Claude Code riprende una sessione da solo quando un limite d'uso si azzera ("Continue automatically at usage limit" in `/config`). A volte non lo fa — un tasto premuto per sbaglio ha annullato il conto alla rovescia, oppure non è mai partito — e la sessione resta ferma finché non te ne accorgi. Fluid fa da rete: il suo modulo di hook annota una sessione che si ferma su un limite, e tre minuti dopo l'azzeramento la ricontrolla. Se è ancora ferma, invia `continue`, come faresti tu.

Per il resto non si intromette. Non viene inviato nulla se Claude Code o tu avete già ripreso, o se nella casella di input c'è qualcosa scritto a metà; prova al massimo due volte, poi ti avvisa. Serve il plugin, in un Claude Code che ne carica il modulo di hook.

## Riavvio dopo un aggiornamento

Claude Code installa gli aggiornamenti in background, ma una sessione in corso resta sulla vecchia build finché non viene riavviata. In tmux, Fluid può farlo al posto tuo: una volta installata una build più recente, una sessione a cui nessuno è collegato, senza un turno in corso, con la casella di input vuota e senza attività da dieci minuti viene riavviata con `claude -r` sulla stessa conversazione, nello stesso pane e nella stessa directory. Le opzioni con cui era stata avviata (`--model`, per esempio) non vengono riportate, e sulla stessa build non si riavvia mai due volte nell'arco di sei ore.

È disattivato per impostazione predefinita. Si attiva nell'`env` di `~/.claude/settings.json`:

```json
"env": { "AUTO_RESTART_TO_UPDATE": "on" }
```

Con `dry` al posto di `on` scrive soltanto nella sessione cosa farebbe. Servono il plugin, in un Claude Code che carica il suo modulo di hook, e tmux 3.0 o successivo.

## Avvisi

Fluid resta in silenzio finché non serve il tuo intervento, e segnala sei cose:

| | |
|---|---|
| **Disconnesso** | L'accesso di un agente è scaduto: per lui non si può aprire nulla finché non rientri |
| **Fallimenti ripetuti** | Diversi warm-up di fila sono falliti per un agente |
| **Pianificatore fermo** | Un'esecuzione pianificata è molto in ritardo, quindi nessuna finestra viene tenuta aperta; di solito `atd` non è in esecuzione |
| **Tornato normale** | Si è ripreso da uno dei problemi sopra |
| **Modello di warm-up sparito** | Il modello con cui un agente veniva scaldato non esiste più, quindi d'ora in poi si usa il suo predefinito |
| **Non ripresa** | Una sessione era ancora ferma dopo l'azzeramento del suo limite d'uso, e nemmeno inviare `continue` l'ha fatta ripartire |

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
