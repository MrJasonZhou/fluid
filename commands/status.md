---
description: Show Claude Plus status for every agent - window, schedule, resume, failures
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fluid.sh:*)"]
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/fluid.sh" status 2>&1`

Present the status. Point out anything that needs the user: atd not running, an overdue schedule, auth problems, failures, or sessions stopped on a limit.
