---
description: Remove Fluid - restores the status line, cancels its jobs, deletes ~/.fluid
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh:*)"]
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/entry.sh" uninstall 2>&1`

Present the output briefly. Tell the user the plugin itself is still installed; `/plugin uninstall fluid` removes it too.
