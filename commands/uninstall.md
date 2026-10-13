---
description: Remove Claude Plus - restores the status line, cancels its jobs, deletes ~/.claude/claude-plus
allowed-tools: Bash(bash:*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/install-claude-plus.sh" uninstall 2>&1`

Present the output briefly. Tell the user the plugin itself is still installed; `/plugin uninstall tailwind` removes it too.
