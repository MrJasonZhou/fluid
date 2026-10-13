---
description: Show or set the time of day Claude Plus opens usage windows at
argument-hint: "[HH:MM|off]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/tailwind.sh:*)"]
---

The argument is: `$ARGUMENTS`

Run `"${CLAUDE_PLUGIN_ROOT}/scripts/tailwind.sh" anchor` followed by the argument when there is one (it accepts only `HH:MM` or `off` and refuses anything else), and present the result in one line.
