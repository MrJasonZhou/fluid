# Claude Plus

English | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [العربية](README.ar.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

Two things your coding agent does not do for you, handled while you are away from the keyboard.

- **Keep the window open** — a new usage window is opened as soon as the last one resets, even while nobody is working, so a full quota is already under way when you come back.
- **Alert** — when that stops working, it tells you: Bark, ntfy, email, or anything else you care to wire up.

Picking a session back up after a usage limit is something the agents now do themselves; when that does not happen, Claude Plus does it for them (see Resume below).

## Agents

Claude Code, Codex and Antigravity all meter a subscription the same way: a short window that starts at your first request, and a longer one on top. Claude Plus keeps whichever of them you have installed.

| Agent | Where its limits come from | Changes to its config |
|---|---|---|
| Claude Code | its status line, on every refresh | one status line entry, one hook |
| Codex | its session logs, read when needed | none |
| Antigravity | its status line, on every refresh | one status line entry |

Each agent gets its own window, schedule and alerts; nothing is shared between them. Adding another is one file — see [docs/PROVIDERS.md](docs/PROVIDERS.md). Agents that meter differently are the reason the interface says so explicitly: Kimi Code's short window limits the rate of requests rather than metering a quota, and Grok Build has one weekly pool and no short window, so for those there would be nothing to keep open.

## Why it helps

**When the window opens decides when it ends.** A window starts at your first request, not at a fixed hour. Begin work at 9:00 with a five-hour window and it runs 9:00-14:00; burn through the quota by 11:00 and you are locked out until 14:00. Had a tiny request opened the window at 6:00 instead, it would expire at 11:00 — exactly when you run dry — with a fresh quota already waiting. With a window always running, one is already under way when you start: whatever is left of it is quota that would otherwise go unused, and a fresh one is at most a window away, usually much less.

**A working day fits more windows when they start early.** Begin at 9:00 and the windows run 9:00-14:00 and 14:00-19:00: two of them before you finish for the day. Have one opened at 6:00 instead and the day is covered by 6:00-11:00, 11:00-16:00 and 16:00-21:00 — three, for the same hours at the desk. The anchor below is how you pin that.

**Knowing when it has stopped helping.** Keeping windows open works until a login expires or the scheduler stops, and then nothing happens at all. Claude Plus notices either and says so, rather than failing quietly all weekend.

## Requirements

Linux, with `jq`, `at` (with `atd` running), `flock`, `timeout`, GNU `date`, and at least one of `claude`, `codex` or `agy`. `tmux` is needed for Resume.

```bash
sudo systemctl enable --now atd
```

## Install

```bash
npx @claude-plus/claude-plus
```

Or from a clone:

```bash
git clone https://github.com/MrJasonZhou/claude-plus.git
cd claude-plus
bash install-claude-plus.sh
```

Or as a Claude Code plugin, whose installer you then run from inside Claude Code:

```
/plugin install tailwind --marketplace MrJasonZhou/claude-plus
/tailwind:install
```

The plugin is called `tailwind`, since plugin names may not start with `claude-`. It brings the Resume hook itself, so the installer leaves that out of your settings, and adds `/tailwind:status`, `/tailwind:anchor` and `/tailwind:uninstall`.

For each agent that has a status line, the installer wraps the one you already had, which keeps showing exactly as before; that, plus one hook for Claude Code (see Resume), is all it changes in that agent's settings, and every settings file is backed up first. Codex needs no configuration at all. Re-running the installer is a clean upgrade rather than a second copy, and it carries over each agent's next scheduled run, its state and your notifier.

## Usage

Day to day there is nothing to run — it works on its own. When you want to look:

```bash
~/.claude/claude-plus/claude-plus.sh status    # every agent: window, schedule, failures
~/.claude/claude-plus/claude-plus.sh providers # which agents are installed
tail -f ~/.claude/claude-plus/claude-plus.log  # what it has been doing
```

## Opening at a fixed time

By default a window opens as soon as the last one resets, so the chain follows whenever you last ran out. To pin it to a time of day instead:

```bash
~/.claude/claude-plus/claude-plus.sh anchor 06:00   # open at 06:00
~/.claude/claude-plus/claude-plus.sh anchor         # show the setting
~/.claude/claude-plus/claude-plus.sh anchor off     # back to opening as soon as it can
```

A window that would run across the anchor waits for it instead: one due at 03:00 would cover 03:00-08:00 and swallow 06:00, so it opens at 06:00. The hours before the anchor are then left without a window — if you work in them, your own first request opens one as usual. The anchor applies to every agent.

## Warm-up model

Opening a window costs one request, so Claude Plus keeps it as small as it can: the cheapest model the agent offers, no tools, nothing written to history. Models come and go, and when an agent no longer knows the one in use it says so plainly — Claude Plus then switches to the agent's own default and tells you, instead of failing window after window until someone reads the log.

```bash
~/.claude/claude-plus/claude-plus.sh model                 # what each agent warms up with
~/.claude/claude-plus/claude-plus.sh model claude sonnet   # choose one yourself
~/.claude/claude-plus/claude-plus.sh model claude auto     # back to the cheapest
```

## Resume

Claude Code picks a session back up by itself when a usage limit resets ("Continue automatically at usage limit" in `/config`). Sometimes it does not — a stray key cancelled the countdown, or it never started — and the session sits there until you notice. Claude Plus is the backstop: it notes each session that stops on a limit, and three minutes after the reset looks again. If the session is still stopped, it types `continue` into its tmux pane.

Otherwise it stays out of the way. Nothing is typed if Claude Code or you have already continued, if you cancelled the countdown with Esc, or if the pane now runs something else; it tries twice at most, then tells you. A session outside tmux has nowhere to type into, so it is only logged.

## Alerts

Claude Plus stays quiet unless something needs you, and tells you about six things:

| | |
|---|---|
| **Signed out** | An agent's login has expired, so nothing can be opened for it until you sign in again |
| **Repeatedly failing** | Several warm-ups in a row have failed for one agent |
| **Scheduler stopped** | A planned run is long overdue, so no window is being kept open; usually `atd` is not running |
| **Back to normal** | It recovered from any of the problems above |
| **Warm-up model gone** | The model an agent was warmed up with no longer exists, so its own default is used from now on |
| **Not resumed** | A session was still stopped after its usage limit reset, and typing `continue` did not get it going either |

Each one is announced once per agent, not on every retry, so a problem overnight costs you a single message. A failure that passes on its own costs nothing at all: a signed-out agent is reported only once a later retry has failed too. Usage limits themselves are never announced: they are routine, and the agents, or Claude Plus behind them, pick up after them.

To choose how you hear about it, copy one of the samples and fill in your own key or server:

```bash
cd ~/.claude/claude-plus
cp notify/bark.sh.sample notify.sh      # or ntfy.sh.sample, email.sh.sample
chmod +x notify.sh                      # use 700 for the email one, it holds a password
$EDITOR notify.sh
./claude-plus.sh notify-test            # make sure it reaches you
```

The notifier is just an executable that receives `CP_EVENT`, `CP_MESSAGE` and `CP_HOST`, so Telegram, Slack, a webhook or `mail` are all a matter of rewriting one line. Your copy survives reinstalls.

## Files

Everything lives in `~/.claude/claude-plus/`:

| | |
|---|---|
| `claude-plus.sh` | The script itself |
| `providers/` | One file per agent |
| `state/<agent>/` | That agent's window, schedule and alert state |
| `notify.sh` | Your notifier, once you set one up |
| `notify/` | Samples to copy from |
| `anchor` | The time of day windows open at, if you set one |
| `claude-plus.log` | What it has been doing |

## Uninstall

```bash
npx @claude-plus/claude-plus uninstall
```

Or from a clone: `bash install-claude-plus.sh uninstall`.

It edits each agent's settings in place and takes out only what Claude Plus added: the status line you had comes back, and every other setting stays exactly as it is — including ones added after Claude Plus was installed. Its scheduled jobs are cancelled and `~/.claude/claude-plus/` is deleted, your `notify.sh` along with it. Running it a second time does no harm.

If another program has since wrapped a status line around Claude Plus, uninstalling will not break it. A small pass-through is left behind so that program keeps working, and the uninstaller tells you so; run it again once nothing needs it any more. Upgrading in the same situation stays inside that program's chain rather than wrapping it.

A copy of every settings file from just before uninstalling is kept next to it, as are the copies made at install time, in case you ever need to go back by hand.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
