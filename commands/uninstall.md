---
description: Remove Claude Plus - restores the status line, cancels its jobs, deletes ~/.claude/claude-plus
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/tailwind.sh:*)"]
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/tailwind.sh" uninstall 2>&1`

Present the output briefly. Tell the user the plugin itself is still installed; `/plugin uninstall tailwind` removes it too.
