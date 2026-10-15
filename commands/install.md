---
description: Install or upgrade Fluid (schedules windows; Claude Code's readings and resume come from the plugin's hooks module)
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh:*)"]
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh" install 2>&1`

Present the installer output briefly. It never edits `~/.claude/settings.json` beyond taking out what versions before 0.3.0 put there; Claude Code's readings and resume come from this plugin's hooks module. If it says the hooks module did not load, explain that windows are kept on estimated resets until it does. If it warns that atd is not running, tell the user to run `sudo systemctl enable --now atd`. For alerts, point them at the samples in `~/.fluid/notify/`. Do not run anything else.
