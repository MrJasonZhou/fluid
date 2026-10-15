# Privacy Policy

Fluid runs entirely on your own machine. It has no server, collects no
analytics, and sends nothing to its author.

## What it reads

- **Usage limits**: for Claude Code, what its plugin's hooks module is told
  inside Claude Code; for Antigravity, its status line payload; for Codex, the
  newest session log. Only the usage-limit fields — how much of the current
  window is used and when it resets.
- **Claude Code's prompt box**, only when a session stopped on a usage limit
  is about to be resumed: the hooks module checks whether anything is typed
  there, so it never sends over a draft. It does not keep what it sees, and it
  does not read the conversation.
- **Antigravity's settings file**, to wrap the status line you already have
  and to restore it when you uninstall, and Claude Code's, only to take out
  what versions before 0.3.0 put there.

## What it stores

Everything lives in `~/.fluid/` on your machine and nowhere else:

- reset times, usage percentages, the time of the next scheduled run, failure
  counts and alert flags;
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
