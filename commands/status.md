---
description: Show Fluid status for every agent - window, schedule, where readings come from, failures
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh:*)"]
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh" status 2>&1`

Present the status. Point out anything that needs the user: atd not running, an overdue schedule, auth problems, failures, or Claude Code readings that are missing or stale (no hooks module loaded).
