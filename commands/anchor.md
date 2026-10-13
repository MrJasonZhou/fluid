---
description: Show or set the time of day Claude Plus opens usage windows at
argument-hint: "[HH:MM|off]"
allowed-tools: Bash(~/.claude/claude-plus/claude-plus.sh anchor:*)
---

The argument is: `$ARGUMENTS`

If it is empty, `off`, or a 24-hour time `HH:MM`, run `~/.claude/claude-plus/claude-plus.sh anchor` with it (nothing for empty) and present the result in one line. Anything else: say the usage is `/tailwind:anchor [HH:MM|off]` and run nothing. If the script does not exist, tell the user to run `/tailwind:install` first.
