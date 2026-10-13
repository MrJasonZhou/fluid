---
description: Install or upgrade Claude Plus (wraps the status line, schedules windows, sets up resume)
allowed-tools: Bash(bash:*)
---

!`CLAUDE_PLUS_HOOK=plugin bash "${CLAUDE_PLUGIN_ROOT}/install-claude-plus.sh" 2>&1`

Present the installer output briefly. It edited `~/.claude/settings.json` only to wrap the status line (a backup sits next to it); the resume hook comes with this plugin. If it warns that atd is not running, tell the user to run `sudo systemctl enable --now atd`. To get alerts, point them at the samples in `~/.claude/claude-plus/notify/` and `/tailwind:status`. Do not run anything else.
