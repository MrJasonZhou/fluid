---
description: Show Claude Plus status for every agent - window, schedule, resume, failures
allowed-tools: Bash(bash:*)
---

!`s="$HOME/.claude/claude-plus/claude-plus.sh"; if [ -x "$s" ]; then "$s" status 2>&1; else echo "Claude Plus is not installed. Run /tailwind:install"; fi`

Present the status. Point out anything that needs the user: atd not running, an overdue schedule, auth problems, failures, or sessions stopped on a limit.
