# Fluid

[English](README.md) | [Deutsch](README.de.md) | Français | [Italiano](README.it.md) | [Português](README.pt.md) | [العربية](README.ar.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

Deux choses que votre agent de code ne fait pas pour vous, prises en charge pendant que vous êtes loin du clavier.

- **Fenêtre toujours ouverte** — une nouvelle fenêtre d'usage s'ouvre dès que la précédente est réinitialisée, même si personne ne travaille : à votre retour, un quota plein est déjà en cours.
- **Alerte** — quand cela ne fonctionne plus, il vous prévient : Bark, ntfy, e-mail, ou tout autre canal que vous voudrez brancher.

Reprendre une session après une limite d'usage, les agents le font désormais eux-mêmes ; quand cela n'arrive pas, Fluid le fait à leur place (voir Reprise plus bas).

## Agents

Claude Code, Codex et Antigravity comptabilisent un abonnement de la même façon : une fenêtre courte qui démarre à votre première requête, et une plus longue par-dessus. Fluid entretient ceux que vous avez installés.

| Agent | D'où viennent ses limites | Modifications de sa configuration |
|---|---|---|
| Claude Code | le module de hooks du plugin Fluid, quand l'utilisation change | aucun |
| Codex | ses journaux de session, lus au besoin | aucune |
| Antigravity | sa status line, à chaque rafraîchissement | une entrée de status line |

Chaque agent a sa propre fenêtre, sa propre planification et ses propres alertes ; rien n'est partagé. En ajouter un autre tient en un fichier — voir [docs/PROVIDERS.md](docs/PROVIDERS.md). Si l'interface précise le mode de comptage, c'est pour une raison : chez Kimi Code, la fenêtre courte limite le débit des requêtes plutôt qu'un quota, et Grok Build n'a qu'un pot hebdomadaire sans fenêtre courte — dans ces cas-là, il n'y aurait aucune fenêtre à garder ouverte.

## À quoi cela sert

**L'heure d'ouverture de la fenêtre décide de son heure de fin.** Une fenêtre démarre à votre première requête, pas à une heure fixe. Avec une fenêtre de cinq heures : commencez à 9h00 et elle court de 9h00 à 14h00 ; épuisez le quota à 11h00 et vous êtes bloqué jusqu'à 14h00. Si une minuscule requête avait ouvert la fenêtre à 6h00, celle-ci expirerait à 11h00 — précisément quand vous êtes à sec — avec un quota neuf déjà prêt. Avec une fenêtre toujours active, il y en a déjà une en cours quand vous commencez : ce qu'il en reste est du quota qui serait sinon perdu, et un quota neuf arrive au plus dans une fenêtre, généralement bien moins.

**Une journée de travail contient plus de fenêtres quand elles commencent tôt.** Commencez à 9h00 et les fenêtres courent de 9h00 à 14h00 puis de 14h00 à 19h00 : deux avant la fin de votre journée. Si l'une s'était ouverte à 6h00, la journée serait couverte par 6h00-11h00, 11h00-16h00 et 16h00-21h00 — trois, pour les mêmes heures au bureau. C'est à cela que sert l'heure fixe, plus bas.

**Savoir quand il a cessé d'aider.** Garder des fenêtres ouvertes ne fonctionne que tant qu'une authentification est valide et que le planificateur tourne ; si l'un des deux s'arrête, plus rien ne se passe. Fluid repère l'un comme l'autre et vous le dit, au lieu d'échouer en silence tout un week-end.

## Prérequis

Linux ou macOS, avec `jq` et au moins l'un de `claude`, `codex` ou `agy`. Pour Claude Code, installez Fluid comme plugin (ci-dessous) : ses mesures et la Reprise viennent du module de hooks du plugin. Sous Linux, les exécutions sont planifiées avec `at`, donc `atd` doit tourner ; sous macOS, c'est launchd qui s'en charge, sans rien à configurer. Sous Windows, lancez Claude Code dans WSL avec systemd activé, pour que atd puisse démarrer.

```bash
sudo systemctl enable --now atd   # Linux
brew install jq                   # macOS
```

## Installation

```bash
npx fluid-agents
```

Ou depuis un clone :

```bash
git clone https://github.com/MrJasonZhou/fluid.git
cd fluid
bash install-fluid.sh
```

Ou en plugin Claude Code, dont vous lancez ensuite l'installateur depuis Claude Code :

```
/plugin install fluid --marketplace MrJasonZhou/fluid
/fluid:install
```

Il ajoute `/fluid:status`, `/fluid:anchor` et `/fluid:uninstall`, ainsi qu'un module de hooks qui tourne dans Claude Code : il transmet à Fluid les mesures d'utilisation et relance une session arrêtée (voir Reprise), sans toucher aux réglages de Claude Code. Les modules de hooks sont encore en cours de déploiement selon les comptes. Là où le module ne se charge pas, ou sans le plugin, les fenêtres de Claude Code restent ouvertes quand même, sur la seule base des heures de réinitialisation estimées, et l'installateur le signale. `/fluid:status` indique d'où viennent les mesures.

Pour Antigravity, l'installateur enveloppe la status line que vous aviez déjà, qui s'affiche exactement comme avant ; c'est la seule modification apportée à ses réglages, et chaque fichier de réglages est sauvegardé au préalable. Codex et Claude Code ne demandent aucune configuration. Relancer l'installateur revient à une mise à jour propre plutôt qu'à une seconde installation, et conserve pour chaque agent sa prochaine exécution planifiée, son état et votre notificateur. Les versions antérieures à 0.3.0 enveloppaient aussi la status line de Claude Code et ajoutaient un hook à ses réglages : désinstallez une fois (ci-dessous) avant d'installer le plugin, et les deux disparaissent.

## Utilisation

Au quotidien, il n'y a rien à lancer — il travaille tout seul. Quand vous voulez regarder :

```bash
~/.fluid/fluid.sh status    # par agent : fenêtre, planification, échecs
~/.fluid/fluid.sh providers # quels agents sont installés
tail -f ~/.fluid/fluid.log  # ce qu'il a fait
```

## Ouvrir à une heure fixe

Par défaut, une fenêtre s'ouvre dès que la précédente est réinitialisée : la chaîne suit donc l'heure à laquelle vous avez épuisé votre quota la dernière fois. Pour la fixer à une heure de la journée :

```bash
~/.fluid/fluid.sh anchor 06:00   # ouvrir à 06h00
~/.fluid/fluid.sh anchor         # afficher le réglage
~/.fluid/fluid.sh anchor off     # revenir à une ouverture dès que possible
```

Une fenêtre qui courrait par-dessus cette heure l'attend : celle prévue à 03h00 couvrirait 03h00-08h00 et avalerait 06h00, elle s'ouvre donc à 06h00. Les heures qui précèdent restent alors sans fenêtre — si vous travaillez à ce moment-là, votre propre première requête en ouvre une comme d'habitude. Le réglage vaut pour tous les agents.

## Modèle utilisé pour le warm-up

Ouvrir une fenêtre coûte une requête : Fluid la réduit donc au minimum, avec le modèle le moins cher de l'agent, sans outils et sans rien écrire dans l'historique. Les modèles vont et viennent ; quand un agent ne connaît plus celui qui est utilisé, il le dit clairement — Fluid bascule alors sur le modèle par défaut de l'agent et vous prévient une fois, au lieu d'échouer fenêtre après fenêtre jusqu'à ce que quelqu'un lise le journal.

```bash
~/.fluid/fluid.sh model                 # avec quoi chaque agent est réchauffé
~/.fluid/fluid.sh model claude sonnet   # en choisir un vous-même
~/.fluid/fluid.sh model claude auto     # revenir au moins cher
```

## Reprise

Claude Code reprend une session de lui-même quand une limite d'usage se réinitialise (« Continue automatically at usage limit » dans `/config`). Parfois il ne le fait pas — une touche pressée par mégarde a annulé le compte à rebours, ou celui-ci n'a jamais démarré — et la session reste en plan jusqu'à ce que vous le remarquiez. Fluid sert de filet : son module de hooks note une session arrêtée sur une limite, et la regarde de nouveau trois minutes après la réinitialisation. Si elle est toujours arrêtée, il envoie `continue`, comme vous le feriez.

Le reste du temps, il ne se mêle de rien. Rien n'est envoyé si Claude Code ou vous avez déjà repris, ou si quelque chose est à moitié saisi dans la zone de saisie ; il essaie deux fois au plus, puis vous prévient. Il faut pour cela le plugin, dans un Claude Code qui charge son module de hooks.

## Alertes

Fluid reste silencieux tant que rien ne requiert votre attention, et ne signale que six choses :

| | |
|---|---|
| **Déconnecté** | L'authentification d'un agent a expiré : rien ne peut être ouvert pour lui tant que vous ne vous reconnectez pas |
| **Échecs répétés** | Plusieurs warm-ups d'affilée ont échoué pour un agent |
| **Planificateur arrêté** | Une exécution prévue a largement dépassé son heure : aucune fenêtre n'est maintenue ouverte ; en général `atd` ne tourne pas |
| **Retour à la normale** | Il s'est remis de l'un des problèmes ci-dessus |
| **Modèle de warm-up disparu** | Le modèle avec lequel un agent était réchauffé n'existe plus ; son propre modèle par défaut est utilisé désormais |
| **Pas reprise** | Une session était toujours arrêtée après la réinitialisation de sa limite d'usage, et envoyer `continue` ne l'a pas relancée non plus |

Chaque cas est signalé une seule fois par agent, pas à chaque nouvelle tentative : un problème nocturne vous coûte un unique message. Une panne qui se résout d'elle-même n'en coûte aucun : un agent déconnecté n'est signalé qu'après l'échec d'une tentative ultérieure. Les limites d'usage elles-mêmes ne sont jamais annoncées : elles sont courantes, et les agents, ou Fluid derrière eux, reprennent ensuite.

Pour choisir comment en être informé, copiez l'un des exemples et renseignez votre clé ou votre serveur :

```bash
cd ~/.fluid
cp notify/bark.sh.sample notify.sh      # ou ntfy.sh.sample, email.sh.sample
chmod +x notify.sh                      # 700 pour celui de l'e-mail, il contient un mot de passe
$EDITOR notify.sh
./fluid.sh notify-test            # vérifier que cela vous parvient
```

Le notificateur n'est qu'un exécutable qui reçoit `CP_EVENT`, `CP_MESSAGE` et `CP_HOST` ; Telegram, Slack, un webhook ou `mail` se résument donc à réécrire une ligne. Votre version survit aux réinstallations.

## Fichiers

Tout se trouve dans `~/.fluid/` :

| | |
|---|---|
| `fluid.sh` | Le script lui-même |
| `providers/` | Un fichier par agent |
| `state/<agent>/` | Fenêtre, planification et état des alertes de cet agent |
| `notify.sh` | Votre notificateur, une fois configuré |
| `notify/` | Exemples à copier |
| `anchor` | L'heure d'ouverture des fenêtres, si vous en avez défini une |
| `fluid.log` | Ce qu'il a fait |

## Désinstallation

```bash
npx fluid-agents uninstall
```

Ou depuis un clone : `bash install-fluid.sh uninstall`.

Elle modifie les réglages de chaque agent sur place et n'en retire que ce que Fluid y a ajouté : votre status line revient, et tous les autres réglages restent exactement tels quels — y compris ceux ajoutés après l'installation. Ses tâches planifiées sont annulées et `~/.fluid/` est supprimé, votre `notify.sh` avec. La relancer une seconde fois ne fait aucun mal.

Si un autre programme a depuis enveloppé une status line autour de Fluid, la désinstallation ne le casse pas. Un petit script relais est laissé en place pour que ce programme continue de fonctionner, et le désinstallateur vous le signale ; relancez-le quand plus rien n'en a besoin. Une mise à jour dans la même situation reste à l'intérieur de la chaîne de ce programme au lieu de l'envelopper à son tour.

Une copie de chaque fichier de réglages datant de juste avant la désinstallation est conservée à côté, tout comme les copies faites à l'installation (les cinq plus récentes), au cas où vous voudriez un jour revenir en arrière à la main.

## Licence

GPL-3.0-or-later. Voir [LICENSE](LICENSE).
