# Privacy Policy

Fluid runs entirely on your own machine. It has no server, collects no
analytics, and sends nothing to its author.

## What it reads

- **Your agent's status line payload** (Claude Code, Antigravity) or, for
  Codex, the newest session log: only the usage-limit fields — how much of the
  current window is used and when it resets.
- **A session's transcript**, only after that session stopped on a usage
  limit: Fluid checks whether the last turn is still the limit error and
  whether the automatic continue was cancelled. It does not read or keep the
  content of the conversation.
- **Your agent's settings file**, to wrap the status line you already have and
  to restore it when you uninstall.

## What it stores

Everything lives in `~/.fluid/` on your machine and nowhere else:

- reset times, usage percentages, the time of the next scheduled run, failure
  counts and alert flags;
- for a session stopped on a limit: its session id, transcript path, tmux pane
  id and the pane's process id and start time, deleted once the session moves
  on;
- `fluid.log`, a record of what Fluid did and when;
- your notifier, `notify.sh`, if you set one up. It may hold a key or password
  you put there yourself; Fluid only runs it.

Uninstalling deletes `~/.fluid/`.

## What leaves your machine

- **Warm-up requests.** To open a usage window, Fluid sends your agent the
  smallest request it can (`Reply only OK.`) through that agent's own CLI. It
  goes to that agent's provider (Anthropic, OpenAI or Google) under your own
  login, like any request you make yourself.
- **Alerts, only if you set up a notifier.** A one-line status message (for
  example "signed out" or "warmups failing") and your host name go to the
  service you chose — Bark, ntfy, email or your own script. No transcript
  content is ever included.

Nothing else is sent anywhere.

## Personal data

Fluid does not collect names, email addresses or other personal data. The
only address it handles is the one you may write into your own email
notifier, and it is used only to send you your alerts.

## Contact

Questions: open an issue at https://github.com/MrJasonZhou/fluid/issues
