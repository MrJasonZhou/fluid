---
description: Show or set the time of day Fluid opens usage windows at
argument-hint: "[HH:MM|off]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh:*)"]
---

The argument is: `$ARGUMENTS`

Run `"${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh" anchor` followed by the argument when there is one (it accepts only `HH:MM` or `off` and refuses anything else), and present the result in one line.
