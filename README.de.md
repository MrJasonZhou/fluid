# Fluid

[English](README.md) | Deutsch | [Français](README.fr.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [العربية](README.ar.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

Zwei Dinge, die Ihr Coding-Agent nicht für Sie erledigt — erledigt, während Sie nicht an der Tastatur sitzen.

- **Fenster offen halten** — sobald das letzte Nutzungsfenster zurückgesetzt wird, öffnet sich ein neues, auch wenn gerade niemand arbeitet; wenn Sie zurückkommen, läuft schon ein volles Kontingent.
- **Benachrichtigen** — funktioniert das nicht mehr, sagt es Ihnen Bescheid: Bark, ntfy, E-Mail oder was immer Sie anschließen möchten.

Eine Sitzung nach einem Nutzungslimit wieder aufzunehmen, erledigen die Agenten inzwischen selbst; wenn das ausbleibt, übernimmt Fluid es für sie (siehe Fortsetzen unten).

## Agenten

Claude Code, Codex und Antigravity messen ein Abo auf dieselbe Weise: ein kurzes Fenster, das mit Ihrer ersten Anfrage beginnt, und darüber ein längeres. Fluid hält offen, was bei Ihnen installiert ist.

| Agent | Woher die Limits kommen | Änderungen an seiner Konfiguration |
|---|---|---|
| Claude Code | seine Status Line, bei jeder Aktualisierung | ein Status-Line-Eintrag, ein Hook |
| Codex | seine Sitzungsprotokolle, bei Bedarf gelesen | keine |
| Antigravity | seine Status Line, bei jeder Aktualisierung | ein Status-Line-Eintrag |

Jeder Agent bekommt sein eigenes Fenster, seinen eigenen Zeitplan und seine eigenen Meldungen; nichts wird geteilt. Einen weiteren hinzuzufügen ist eine Datei — siehe [docs/PROVIDERS.md](docs/PROVIDERS.md). Dass die Schnittstelle die Art der Messung ausdrücklich nennt, hat einen Grund: Bei Kimi Code begrenzt das kurze Fenster die Rate der Anfragen statt ein Kontingent zu messen, und Grok Build hat einen Wochentopf und gar kein kurzes Fenster — da gäbe es nichts offen zu halten.

## Wozu das gut ist

**Wann das Fenster öffnet, entscheidet, wann es endet.** Ein Fenster beginnt mit Ihrer ersten Anfrage, nicht zu einer festen Uhrzeit. Bei einem Fünf-Stunden-Fenster: Beginnen Sie um 9:00 zu arbeiten, läuft es von 9:00 bis 14:00; ist das Kontingent um 11:00 aufgebraucht, sind Sie bis 14:00 ausgesperrt. Hätte stattdessen eine winzige Anfrage das Fenster um 6:00 geöffnet, liefe es um 11:00 ab — genau dann, wenn Ihnen der Vorrat ausgeht — und ein frisches Kontingent stünde bereit. Läuft ständig ein Fenster, ist beim Arbeitsbeginn schon eines im Gang: Was davon übrig ist, wäre sonst ungenutzt verfallen, und ein frisches Kontingent ist höchstens ein Fenster entfernt, meist viel weniger.

**Früh geöffnete Fenster passen öfter in einen Arbeitstag.** Beginnen Sie um 9:00, laufen die Fenster von 9:00 bis 14:00 und von 14:00 bis 19:00 — zwei bis zum Feierabend. Wurde stattdessen um 6:00 eines geöffnet, deckt der Tag 6:00-11:00, 11:00-16:00 und 16:00-21:00 ab: drei, bei derselben Zeit am Schreibtisch. Dafür ist die feste Uhrzeit weiter unten da.

**Erkennen, wann es nicht mehr hilft.** Fenster offen zu halten funktioniert nur, solange eine Anmeldung gültig ist und der Planer läuft; fällt eines davon aus, passiert gar nichts. Fluid bemerkt beides und sagt es Ihnen, statt ein ganzes Wochenende lang still zu scheitern.

## Voraussetzungen

Linux oder macOS, mit `jq` und mindestens einem von `claude`, `codex` oder `agy`. Unter Linux werden Läufe mit `at` eingeplant, also muss `atd` laufen; unter macOS übernimmt das launchd, ohne jede Einrichtung. Für Fortsetzen wird `tmux` gebraucht. Unter Windows läuft Claude Code in WSL mit aktiviertem systemd, damit atd starten kann.

```bash
sudo systemctl enable --now atd   # Linux
brew install jq tmux              # macOS
```

## Installation

```bash
npx fluid-agents
```

Oder aus einem Klon:

```bash
git clone https://github.com/MrJasonZhou/fluid.git
cd fluid
bash install-fluid.sh
```

Oder als Claude-Code-Plugin, dessen Installer Sie dann in Claude Code selbst starten:

```
/plugin install fluid --marketplace MrJasonZhou/fluid
/fluid:install
```

Es bringt den Hook für Fortsetzen selbst mit, deshalb trägt der Installer ihn nicht in Ihre Einstellungen ein, und fügt `/fluid:status`, `/fluid:anchor` und `/fluid:uninstall` hinzu.

Für jeden Agenten mit einer Status Line legt sich der Installer um die, die Sie bereits hatten, und die wird genau wie bisher angezeigt; das ist, neben einem Hook für Claude Code (siehe Fortsetzen), die einzige Änderung an den Einstellungen jenes Agenten, und jede Einstellungsdatei wird zuvor gesichert. Codex braucht überhaupt keine Konfiguration. Ein erneuter Lauf ist ein sauberes Upgrade statt einer zweiten Installation und übernimmt für jeden Agenten den nächsten geplanten Lauf, seinen Zustand und Ihren Benachrichtiger.

## Verwendung

Im Alltag gibt es nichts auszuführen — es arbeitet von selbst. Wenn Sie nachsehen möchten:

```bash
~/.fluid/fluid.sh status    # je Agent: Fenster, Zeitplan, Fehlschläge
~/.fluid/fluid.sh providers # welche Agenten installiert sind
tail -f ~/.fluid/fluid.log  # was es getan hat
```

## Zu einer festen Uhrzeit öffnen

Standardmäßig öffnet ein Fenster, sobald das letzte zurückgesetzt wird; die Kette folgt also dem Zeitpunkt, an dem Sie zuletzt nichts mehr hatten. Um sie stattdessen an eine Uhrzeit zu binden:

```bash
~/.fluid/fluid.sh anchor 06:00   # um 06:00 öffnen
~/.fluid/fluid.sh anchor         # die Einstellung anzeigen
~/.fluid/fluid.sh anchor off     # wieder öffnen, sobald es geht
```

Ein Fenster, das über diese Uhrzeit hinweglaufen würde, wartet stattdessen auf sie: eines, das um 03:00 fällig wäre, deckte 03:00-08:00 ab und verschlänge 06:00, also öffnet es um 06:00. Die Stunden davor bleiben dann ohne Fenster — arbeiten Sie darin, öffnet Ihre eigene erste Anfrage wie gewohnt eines. Die Uhrzeit gilt für alle Agenten.

## Modell für das Warm-up

Ein Fenster zu öffnen kostet eine Anfrage, also hält Fluid sie so klein wie möglich: das günstigste Modell des jeweiligen Agenten, keine Werkzeuge, nichts im Verlauf. Modelle kommen und gehen, und wenn ein Agent das gerade benutzte nicht mehr kennt, sagt er das deutlich — Fluid wechselt dann auf das eigene Standardmodell des Agenten und sagt Ihnen einmal Bescheid, statt Fenster für Fenster zu scheitern, bis jemand das Log liest.

```bash
~/.fluid/fluid.sh model                 # womit jeder Agent aufgewärmt wird
~/.fluid/fluid.sh model claude sonnet   # selbst eines wählen
~/.fluid/fluid.sh model claude auto     # zurück zum günstigsten
```

## Fortsetzen

Claude Code nimmt eine Sitzung von selbst wieder auf, wenn ein Nutzungslimit zurückgesetzt wird („Continue automatically at usage limit“ in `/config`). Manchmal passiert das nicht — eine versehentliche Taste hat den Countdown abgebrochen, oder er ist nie gestartet — und die Sitzung steht, bis Sie es bemerken. Fluid ist das Netz darunter: Es merkt sich jede Sitzung, die an einem Limit stehen bleibt, und schaut drei Minuten nach dem Reset noch einmal nach. Steht sie immer noch, tippt es `continue` in ihr tmux-Pane.

Ansonsten hält es sich heraus. Getippt wird nichts, wenn Claude Code oder Sie schon weitergemacht haben, wenn Sie den Countdown mit Esc abgebrochen haben oder wenn im Pane inzwischen etwas anderes läuft; nach höchstens zwei Versuchen sagt es Ihnen Bescheid. Eine Sitzung außerhalb von tmux bietet nichts, wohin getippt werden könnte, also wird sie nur protokolliert.

## Benachrichtigungen

Fluid bleibt still, solange nichts Ihre Aufmerksamkeit braucht, und meldet sechs Dinge:

| | |
|---|---|
| **Abgemeldet** | Die Anmeldung eines Agenten ist abgelaufen; für ihn lässt sich nichts öffnen, bis Sie sich neu anmelden |
| **Wiederholt fehlgeschlagen** | Mehrere Warm-ups hintereinander sind für einen Agenten fehlgeschlagen |
| **Planer steht** | Ein geplanter Lauf ist längst überfällig, es wird also kein Fenster offen gehalten; meist läuft `atd` nicht |
| **Wieder normal** | Es hat sich von einem der obigen Probleme erholt |
| **Warm-up-Modell verschwunden** | Das Modell, mit dem ein Agent aufgewärmt wurde, gibt es nicht mehr; ab jetzt wird sein eigenes Standardmodell verwendet |
| **Nicht fortgesetzt** | Eine Sitzung stand nach dem Reset ihres Nutzungslimits immer noch, und auch ein getipptes `continue` hat sie nicht in Gang gebracht |

Jede Meldung kommt einmal je Agent, nicht bei jedem Wiederholungsversuch — ein nächtliches Problem kostet Sie also eine einzige Nachricht. Ein Fehler, der von selbst vergeht, kostet gar keine: Dass ein Agent abgemeldet ist, wird erst gemeldet, wenn auch ein späterer Versuch fehlschlägt. Über Nutzungslimits selbst wird nie berichtet: Sie sind Alltag, und die Agenten — oder Fluid hinter ihnen — machen danach weiter.

Um zu wählen, wie Sie davon erfahren, kopieren Sie eine der Vorlagen und tragen Ihren eigenen Schlüssel oder Server ein:

```bash
cd ~/.fluid
cp notify/bark.sh.sample notify.sh      # oder ntfy.sh.sample, email.sh.sample
chmod +x notify.sh                      # für die E-Mail-Variante 700, sie enthält ein Passwort
$EDITOR notify.sh
./fluid.sh notify-test            # prüfen, ob es Sie erreicht
```

Der Benachrichtiger ist nur eine ausführbare Datei, die `CP_EVENT`, `CP_MESSAGE` und `CP_HOST` erhält. Telegram, Slack, ein Webhook oder `mail` sind daher eine Frage einer einzigen Zeile. Ihre Fassung übersteht Neuinstallationen.

## Dateien

Alles liegt unter `~/.fluid/`:

| | |
|---|---|
| `fluid.sh` | Das Skript selbst |
| `providers/` | Eine Datei je Agent |
| `state/<Agent>/` | Fenster, Zeitplan und Meldungszustand jenes Agenten |
| `notify.sh` | Ihr Benachrichtiger, sobald Sie einen einrichten |
| `notify/` | Vorlagen zum Kopieren |
| `anchor` | Die Uhrzeit, zu der Fenster öffnen, falls gesetzt |
| `fluid.log` | Was es getan hat |

## Deinstallation

```bash
npx fluid-agents uninstall
```

Oder aus einem Klon: `bash install-fluid.sh uninstall`.

Es bearbeitet die Einstellungen jedes Agenten direkt und entfernt nur, was Fluid hinzugefügt hat: Ihre Status Line kommt zurück, und alle anderen Einstellungen bleiben genau so, wie sie sind — auch solche, die nach der Installation dazugekommen sind. Die geplanten Jobs werden abgebrochen und `~/.fluid/` wird gelöscht, Ihre `notify.sh` mit ihm. Ein zweiter Aufruf richtet keinen Schaden an.

Hat inzwischen ein anderes Programm eine Status Line um Fluid herum gelegt, macht die Deinstallation es nicht kaputt. Ein kleines Durchreich-Skript bleibt zurück, damit jenes Programm weiter funktioniert, und der Deinstaller weist darauf hin; führen Sie ihn erneut aus, sobald es nicht mehr gebraucht wird. Ein Upgrade in derselben Lage bleibt innerhalb der Kette jenes Programms, statt es seinerseits einzuwickeln.

Eine Kopie jeder Einstellungsdatei von unmittelbar vor der Deinstallation bleibt daneben liegen, ebenso die bei der Installation angelegten Kopien (jeweils die fünf neuesten) — für den Fall, dass Sie je von Hand zurückwollen.

## Lizenz

GPL-3.0-or-later. Siehe [LICENSE](LICENSE).
