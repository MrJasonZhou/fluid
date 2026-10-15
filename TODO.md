# TODO

Analysis of 2.3.1, 2026-09-17, revised since. The scheduler check listed here
went into 2.4.0, 3.0.0 removed Resume (see Decided against), 3.1.0 added an
anchor time after all, 4.0.0 split out the provider layer and added Codex and
Antigravity, 4.1.0 made the warmup model replaceable, and 4.1.1 stopped a
refresh that fixes itself from being reported as a signed-out agent, 4.2.0
brought Resume back as a backstop behind the agent's own continue, and 4.3.0
packaged it as a Claude Code plugin named `fluid` (`tailwind` before 4.3.2,
which came too close to other listings), and the whole project was then renamed
from Claude Plus to Fluid, starting over at 0.1.0 (repository, npm package `fluid-agents`, and
`~/.fluid` in place of `~/.claude/claude-plus`, with no migration), and 0.2.0 added macOS:
launchd one-shot agents instead of `at`, with stand-ins for flock, GNU
date, timeout, tac and /proc, and 0.2.1 fixed what a review of error handling
and of the effect on running sessions and jobs found (launchd PATH, the at
working directory, locks held past their use, uninstall racing a run in
progress, settings behind a symlink, and more; see the 0.2.1 commits), and 0.2.3
stopped a status line killed mid-refresh from leaving half-written at jobs
behind, and 0.3.0 moved Claude Code over to the plugin's hooks module alone:
readings and resume come from inside Claude Code, its settings are never
edited, and the status line wrapper, the StopFailure hook and the tmux
backstop are gone for it; nothing else has been started. Code is referred to by
function name rather than line number, since lines move.

## Features

### The hooks module (0.3.0)

Claude Code's readings and resume come only from the plugin's hooks module.
Installed plugins' hooks modules load only where Claude Code's rollout flag
`tengu_plugin_hooks_modules` is on for the account, and Claude Code ships the
rollout to everyone in time, so there is no fallback: where the module does
not load, or without the plugin, nothing is planned for Claude Code until a
first reading arrives, after which the chain runs on estimated resets alone;
the installer says so when the module did not load. Installs before 0.3.0
wrapped Claude Code's status line and added a StopFailure hook; uninstalling (or installing
0.3.0) takes both out, through the same strip filter as ever. Open:

- Whether `$` stays usable after a hook returns: readings are handed over
  with `void observe($, ...)`, and the resume ticker runs on `$.clock.every`
  from the hook that armed it. Fine in the engine's test kit; unverified in a
  real session.
- Resume from inside Claude Code is tested against the engine's test kit, not
  yet against a real usage limit. `prompt.submit` with `asUser` sends
  `continue` as the person would; the draft in the prompt box is checked
  first, so nothing is mixed into what someone is typing.

### Medium priority

#### Estimated resets can shift the chain by five hours

Warmups run with `--safe-mode`, so no status line runs and no official
`resets_at` is seen. While Claude Code is closed, the chain runs on estimates
alone. If an estimate is early, the warmup lands before the old window has
reset: it is counted against the old window, no new window opens, yet the
warmup reports success and the next one is set five hours later. The chain is
then idle for a window it could have used.

Needs research: a way to read current usage or the next reset without the
interactive UI (see Open questions).

#### Keep state private

`original-statusline-command` is run through `bash -c`, and `state/` and the
log describe when the user works. Everything inherits the default umask and is
typically readable by other local users. `umask 077` in the installer and the
generated script would close this.

### Low priority

- Native Windows: runs would need `schtasks`; Resume, now inside Claude Code,
  would work as it is. WSL works as
  Linux, so this waits for someone to ask.
- macOS (0.2.0) is tested in CI on the system bash 3.2 with fake launchd, but
  not yet on a real Mac: a one-shot agent's behaviour across sleep, and
  `launchctl bootstrap` from an SSH session with nobody logged in, are
  unverified, and so is whether `claude -p` started by launchd can read the
  login in the Keychain; if it cannot, Keep does nothing on a Mac.
- No way to turn one agent off without uninstalling. Deleting its file under
  `providers/` works until the next upgrade rewrites it.
- Kimi Code and Grok Build are understood but not implemented: Kimi's short
  window limits the rate of requests rather than metering quota, and Grok has
  one weekly pool and no short window, so neither has a window worth keeping.
  Both would still earn `alert` if anyone wants the auth and scheduler
  warnings for them.
- `fluid.log` is never pruned. It grows slowly.

### Decided against

- **Resume, removed in 3.0.0; back in 4.2.0 as a backstop.** Claude Code resumes a session by itself when a
  usage limit resets: the CLI's `/config` has "Continue automatically at usage
  limit" (`autoContinueAtUsageLimit`, on by default), and Desktop has an
  "Auto-continue when limits reset" checkbox. It runs inside the session, needs
  no tmux, and can be cancelled with Esc.
  Two real limit hits on 2026-09-16 and 09-17 showed Resume getting in its
  way. Both `continue` prompts in the transcript carry
  `origin: {kind: "human"}` and `promptSource: "typed"`, and arrived when atd
  ran the job at the top of the minute (0.26 s and 10 s after the reset), so
  Fluid's tmux keystrokes went first each time. On the second, the user
  had pressed Esc - the transcript records `Automatic continue cancelled` - and
  Resume continued anyway.
  What the native feature does not cover (weekly limits more than a day out,
  sleeping through the reset, the setting turned off, older Claude Code) is
  either reachable through `/rate-limit-options`, a single keypress, or a
  choice the user made. Not worth tmux, three hooks and the process-identity
  checks that came with it.
  It came back after 2026-10-12, when a session in tmux with the setting on
  sat idle for hours past its reset: no continue and no "cancelled" notice in
  the transcript. 4.2.0 answers both objections above: it waits
  `RESUME_GRACE` (180 s) past the reset so the native feature goes first, and
  reads the transcript instead of keeping state from UserPromptSubmit and
  SessionEnd hooks, so a session that has moved on or was cancelled with Esc
  is left alone. One `StopFailure` hook is all it adds.
  0.3.0 moved it into the plugin's hooks module, which sends `continue` from
  inside Claude Code: no tmux, no pane identity checks, and a half-typed
  draft in the prompt box is seen directly.
- **Anchoring Keep to a time of day: reconsidered, shipped in 3.1.0.** The
  argument below still holds - whatever the phase, Keep is never worse than
  none - so this was left out at first. It went in anyway because a window
  opening at a time you choose is worth having on its own: `anchor HH:MM` holds
  back any window that would run across that time, so one opens on it instead.
  For the record, the original reasoning: the worry was that the chain's phase
  is set by when the user last ran out, so work might start in the last half
  hour of a window. That is not a loss: an overnight window is unused, so that
  half hour is quota that would otherwise go to waste, and the next full window
  is only half an hour away. With r hours left in the current window when work
  starts, a smaller r is better; the worst case, r close to five hours, is the
  same as having no Keep at all.
- **Asking the model which model to warm up with.** The idea was to end each
  warmup by asking which model will be cheapest in twelve hours and use that
  one next time, so the hard-coded id could never go stale. Tried on
  2026-09-25: Haiku answered "I cannot predict price changes twelve hours
  from now. I have no real-time pricing data" - and an answer it did give
  would be a guess, possibly a model id that does not exist. The dependency
  is circular too: once the id is dead, the question cannot be asked either.
  What went in instead (4.1.0) is a fallback. A dead id gives exit code 1 and
  an output carrying `unrecognized_model`, which is not matched by the
  expired-login pattern, so it can be told apart: the warmup is retried with
  no model at all, the fallback is remembered per agent, and one alert names
  the model. `fluid.sh model <agent> <name>` overrides it by hand.
- **A watchdog independent of `at`.** The scheduler check runs on status line
  refreshes, so a scheduler that stops overnight is only noticed the next time
  Claude Code starts. Catching it sooner would take cron or a systemd timer,
  one more dependency; the delay is acceptable.

## Platforms

### Platform dependencies

0.2.0 gathered every call that assumes one system into a handful of helpers
(`fmt_time`, `parse_time`, `with_timeout`, `reverse_lines`, `take_lock`) and
the scheduler functions, so the rest of the script is the same everywhere.

| Dependency | Used for | Linux | macOS | Windows (native) |
|---|---|---|---|---|
| `date` | time conversion | GNU `date -d` | BSD `date -r` / `-j -f` | n/a |
| scheduler | queued runs | `at` / `atq` / `atrm` | one-shot launchd agents | Task Scheduler |
| `flock` | locking | `flock` | a directory lock with the holder's pid | missing |
| `timeout` | time limits | `timeout` | `gtimeout`, or perl `alarm` | present in Git Bash |
| `tac` | reading logs backwards | `tac` | `tail -r` | n/a |
| bash | the script itself | any | system bash 3.2, kept clean for it | Git Bash is 5.x |

### WSL

If Claude Code runs inside WSL, Fluid already works: it is Linux. Two
things to verify and document:
- WSL shuts its VM down when idle. With no terminal open, the VM may be gone
  when an `at` job is due, and the job does not run. The scheduler check would
  then report a stall the next time Claude Code starts.
- WSL does not run systemd by default, so `atd` has to be started by hand or
  systemd enabled.

Expected work: testing on a real machine and documentation; little or no code.

### macOS

Shipped in 0.2.0 and tested in CI on the system bash 3.2 without GNU
coreutils. What is left needs a real Mac (see Low priority): the Keychain from
launchd, a run that falls due while the lid is closed, and `launchctl
bootstrap` from an SSH session.

### Windows (native)

Keep and Alert are possible, but scheduling, locking and the settings path all
need different implementations, and how Claude Code runs hook commands on
native Windows needs checking. In practice this is a second implementation in
PowerShell or Node.

Recommendation: not now.

### Packaging the runtime script

The runtime script, a heredoc in the installer, could ship as its own file in
the package and be copied into place. With providers it is now several
heredocs, which makes the case a little stronger.

A rewrite in Node is not recommended for now. It would drop jq and unify JSON
and subprocess handling, but scheduling, the hardest part, would still depend
on each platform, and installing from a git clone would start to require Node.

## Open questions

- Can `claude -p` started by launchd or `at` on macOS read Keychain credentials?
- How does WSL's idle VM shutdown affect `at` jobs in practice?
- Which shell does Claude Code use for hook commands on native Windows?
- Can `claude -p`, or anything else outside the interactive UI, report the
  next quota reset?
- Are five-hour reset times aligned to a fixed granularity? Every observed
  value so far has been at twenty past the hour (14:20, 18:20, 19:20 JST).

## Suggested order

1. `umask 077`.
2. WSL: verify on a real machine, then document.
3. Research reading usage without the interactive UI.
4. macOS: try it on a real Mac, Keychain access first.
5. Native Windows: not now.
