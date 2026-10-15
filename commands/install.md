---
description: Install or upgrade Fluid (reads usage through its hooks module or the status line, schedules windows, sets up resume)
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh:*)"]
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh" install 2>&1`

Present the installer output briefly. Where it says Claude Code's readings come from the plugin's hooks module, it left `~/.claude/settings.json` untouched; otherwise it edited that file only to wrap the status line (a backup sits next to it). The resume hook comes with this plugin. If it warns that atd is not running, tell the user to run `sudo systemctl enable --now atd`. For alerts, point them at the samples in `~/.fluid/notify/`. Do not run anything else.
