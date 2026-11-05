// Fluid - enhancements for coding agents
// Copyright (C) 2026 Jason Zhou
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

// The hooks module running inside Claude Code. It hands usage readings to fluid.sh
// without wrapping the status line, and resumes sessions stopped on a limit from inside the process.
// It touches no settings file.
//
// Sessions that load this module get FLUID_MOD=1. A /fluid:install started from
// one sees it and says whether readings will arrive.
// Since 0.3.0 this module alone handles Claude Code's readings and resume.

import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

// Same as fluid.sh's RESUME_GRACE: time after a reset left for the agent to carry on by itself
export const GRACE_MS = 180_000
// Time between sending continue and checking whether it worked
export const VERIFY_MS = 90_000
// Give up and say so after this many sends that leave it stopped
export const MAX_ATTEMPTS = 2
// How often to look while waiting. Waking from sleep catches up on the next look
export const TICK_MS = 30_000
// How long before retrying to say it gave up, when that could not be delivered
export const NOTIFY_RETRY_MS = 600_000
// Margin for not mistaking a turn started by our own continue for someone else's
const OWN_TURN_MS = 10_000

type Reading = {
  rate_limits: Record<string, { used_percentage: number; resets_at?: number }>
}

type Pending = {
  // When to look next
  dueAt: number
  // How many times it was sent
  attempts: number
  // When it was last sent
  sentAt?: number
  // Sending continue right now. A turn starting meanwhile is ours
  isSending?: boolean
}

// State held only for the session. Reloading the module starts it afresh
type State = {
  limits: readonly SessionRateLimit[]
  pending?: Pending
  isTurnRunning: boolean
  ticker?: { cancel: () => void }
  // In the middle of a look. A look outlasting the next tick does not get a second one
  isTicking?: boolean
}

// Shape Claude Code's rateLimits like the JSON the status line hands over, so fluid.sh's
// claude_parse_limits reads it as is
export function toReading(limits: readonly SessionRateLimit[]): Reading | undefined {
  const windows: Reading['rate_limits'] = {}

  for (const limit of limits) {
    if (limit.kind !== 'five_hour' && limit.kind !== 'seven_day') continue

    const window: { used_percentage: number; resets_at?: number } = {
      used_percentage: limit.percentUsed,
    }
    const at = limit.resetsAt === undefined ? NaN : Date.parse(limit.resetsAt)
    if (!Number.isNaN(at)) window.resets_at = Math.floor(at / 1000)
    windows[limit.kind] = window
  }

  return Object.keys(windows).length > 0 ? { rate_limits: windows } : undefined
}

// Whether any window is used up. In an organisation-managed Claude Code StopFailure does
// not reach installed plugins, so this is how a turn that ended in an error is told apart
export function isLimited(limits: readonly SessionRateLimit[]): boolean {
  return limits.some(l => (l.kind === 'five_hour' || l.kind === 'seven_day') && l.percentUsed >= 99.9)
}

// When the window that stopped it opens (ms): the long one when it is full, else the short one.
// With the long window full and its opening unknown, answer unknown: sending at the short
// window's time would only stop again
export function resetAt(limits: readonly SessionRateLimit[], now: number): number | undefined {
  const parse = (kind: string) => {
    const limit = limits.find(l => l.kind === kind)
    return { t: limit?.resetsAt === undefined ? NaN : Date.parse(limit.resetsAt), percent: limit?.percentUsed ?? 0 }
  }

  const long = parse('seven_day')
  if (long.percent >= 99.9) {
    if (Number.isNaN(long.t)) return undefined
    if (long.t > now) return long.t
  }
  const short = parse('five_hour')
  return Number.isNaN(short.t) || short.t <= now ? undefined : short.t
}

// Call fluid.sh once. Does nothing when it is not installed (before /fluid:install).
// Returns whether it worked
async function fluid($: EngineInterface, args: string[], stdin?: string): Promise<boolean> {
  const home = await $.env.get('HOME')
  if (home === undefined) return false
  try {
    // Stopping in the middle of writing to at leaves a half-made job (0.2.3). What waits here
    // is not a hook, so give it room
    const result = await $.process.run([`${home}/.fluid/fluid.sh`, ...args], { cwd: '/', stdin, timeoutMs: 60_000 })
    return result.exitCode === 0
  } catch {
    // Not installed, or a passing failure. The next reading comes round again
    return false
  }
}

// Whether Fluid is installed. With only the plugin in, or after /fluid:uninstall,
// nothing is sent to the session
async function isInstalled($: EngineInterface): Promise<boolean> {
  const home = await $.env.get('HOME')
  if (home === undefined) return false
  try {
    return await $.fs.exists(`${home}/.fluid/fluid.sh`)
  } catch {
    return false
  }
}

async function observe($: EngineInterface, state: State) {
  const reading = toReading(state.limits)
  if (reading !== undefined) await fluid($, ['observe', 'claude', 'mod'], JSON.stringify(reading))
}

function stopWatching(state: State) {
  state.ticker?.cancel()
  state.ticker = undefined
  state.pending = undefined
}

// Looking after a waiting resume, one at a time so they do not overlap
async function tick($: EngineInterface, state: State) {
  if (state.isTicking) return
  state.isTicking = true
  try {
    await tickOnce($, state)
  } finally {
    state.isTicking = false
  }
}

async function tickOnce($: EngineInterface, state: State) {
  const pending = state.pending
  if (pending === undefined) return stopWatching(state)

  const now = await $.clock.now()
  if (now < pending.dueAt || state.isTurnRunning) return

  // Saying it gave up is retried until delivered (notifier not set up yet, a passing failure)
  if (pending.attempts >= MAX_ATTEMPTS) {
    const isDelivered = await fluid($, ['notify', 'resume-failed',
      `Claude Code did not continue a session after its usage limit reset, and neither did Fluid after ${pending.attempts} tries. It is waiting for you.`])
    if (state.pending !== pending) return
    if (isDelivered) stopWatching(state)
    else pending.dueAt = now + NOTIFY_RETRY_MS
    return
  }

  // If /fluid:uninstall ran during the wait, send nothing more. Check before reading
  // the prompt box: nothing waits between reading it and sending
  if (!(await isInstalled($))) {
    stopWatching(state)
    return
  }
  if (state.pending !== pending || state.isTurnRunning) return

  // Something half-typed in the prompt box means someone is there. Leave it to them rather than mix in
  const box = await $.prompt.read()
  if (box.text.trim() !== '') {
    stopWatching(state)
    await fluid($, ['log', 'claude', 'Someone is typing in the stopped session; leaving it to them'])
    return
  }

  // If someone (the agent itself included) carried on while the prompt box was read, do not send
  if (state.pending !== pending || state.isTurnRunning) return

  pending.attempts += 1
  pending.isSending = true
  try {
    await $.prompt.submit({ text: 'continue', asUser: true })
  } finally {
    pending.isSending = false
  }
  // Take the time after sending, so a slow prompt box read does not make our own turn
  // look like someone else's
  pending.sentAt = await $.clock.now()
  pending.dueAt = pending.sentAt + VERIFY_MS
  void fluid($, ['log', 'claude', `Sent continue to the stopped session, attempt ${pending.attempts}`])
}

// Stopped on a limit: look again after the reset and the grace after it
async function stopped($: EngineInterface, state: State) {
  // With Fluid not installed, a stopped session is left alone
  if (!(await isInstalled($))) {
    stopWatching(state)
    return
  }

  const now = await $.clock.now()
  state.limits = (await $.session.usage()).rateLimits
  const reset = resetAt(state.limits, now)

  // Without a usage window with a known opening time (the subscription's 5-hour or weekly),
  // what stopped it is not a Fluid window: an API key, a gateway's 429 and the like.
  // Carrying on would mean paying per use while nobody is there, so do not send
  if (reset === undefined) {
    stopWatching(state)
    await fluid($, ['log', 'claude', 'Stopped on a limit with no usage window to wait for; not resuming'])
    return
  }

  const dueAt = reset + GRACE_MS

  // StopFailure and a turn ending in an error can both report the same stop
  if (state.pending !== undefined && state.pending.sentAt === undefined && state.pending.dueAt === dueAt) return

  // When the continue sent hits the limit again, the count carries over
  state.pending = { dueAt, attempts: state.pending?.attempts ?? 0 }
  state.isTurnRunning = false
  state.ticker ??= $.clock.every(TICK_MS, () => void tick($, state))

  await fluid($, ['log', 'claude',
    `Usage limit hit; the hooks module looks again at ${new Date(state.pending.dueAt).toISOString()}`])
}

// A main-thread turn started. If the agent itself or a person carried on, stop waiting
async function turnStarted($: EngineInterface, state: State) {
  state.isTurnRunning = true
  const pending = state.pending
  if (pending === undefined) return

  if (pending.isSending) return
  const now = await $.clock.now()
  const isOwn = pending.sentAt !== undefined && now - pending.sentAt < OWN_TURN_MS
  if (!isOwn) stopWatching(state)
}

// Restart to update: when Claude Code has installed a newer build in the
// background, a session in tmux that nobody is attached to, with no turn
// running, nothing in flight or waiting to wake it, an empty prompt box and
// nothing done for RESTART_IDLE_MS, has tmux replace its process with
// `claude -r <session id>`, then a shell. A session that took a Remote Control
// prompt, or ran /remote-control, comes back with --remote-control.
// Once an update is there, each thing that holds the restart back is written
// to fluid's log, once per build, so a session left behind says why.
// AUTO_RESTART_TO_UPDATE in the settings' env: `on` restarts, `dry` only logs
// what it would do, anything else (the default) does nothing.

export const RESTART_CHECK_MS = 5 * 60_000
export const RESTART_IDLE_MS = 10 * 60_000
// A session never tries a restart onto the same version twice within this
// window, so a claude on PATH other than the running one cannot loop
export const RESTART_RETRY_MS = 6 * 60 * 60_000

type Restart = {
  isTurnRunning: boolean
  lastActivity: number
  // As of the last Stop: background work still in flight, or a wakeup this
  // session is waiting for
  hasPendingWork?: boolean
  isChecking?: boolean
  // Dry mode logs each target version once
  loggedFor?: string
  // What held the restart back, already logged for this target version
  heldFor?: string
  held?: string[]
  // Remote Control was used here: the restart brings it back
  isRemote?: boolean
  ticker?: { cancel: () => void }
}

// "2.1.306 (Claude Code)" -> "2.1.306"
export function parseVersion(text: string): string | undefined {
  return /^\s*(\d+\.\d+\.\d+\S*)/.exec(text)?.[1]
}

// Whether release a is past release b, on major.minor.patch alone: a build
// of the same release (a -dev suffix) is not newer
export function isNewer(a: string, b: string): boolean {
  const parse = (v: string) => (/^(\d+)\.(\d+)\.(\d+)/.exec(v) ?? []).slice(1).map(Number)
  const x = parse(a)
  const y = parse(b)
  if (x.length !== 3 || y.length !== 3) return false
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i]! > y[i]!
  return false
}

// Local date and time to the minute, 2026-10-26 14:03
export function stamp(ms: number): string {
  const d = new Date(ms)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

// Runs a script with its arguments as $1..., never spliced into the script
async function sh($: EngineInterface, script: string, args: string[] = []): Promise<string | undefined> {
  const r = await $.process.run(['sh', '-c', script, 'sh', ...args], { cwd: '/', timeoutMs: 10_000 })
  return r.exitCode === 0 ? r.stdout.trim() : undefined
}

// Whether any client attached to the session typed within RESTART_IDLE_MS.
// A client silent that long counts as gone: an ssh connection that dropped
// without a FIN leaves its tmux client attached until TCP gives up, hours later
export function hasLiveClient(activity: string, now: number): boolean {
  return activity.split('\n').some(line => {
    const at = Number(line.trim())
    return line.trim() !== '' && (!Number.isFinite(at) || now - at * 1000 < RESTART_IDLE_MS)
  })
}

// What says someone is there, if anything: a turn running, a client attached to
// the pane's session that has typed lately, something in the prompt box. Asked
// again right before the respawn, since a person may come back while anything
// slow runs
async function whyAttended($: EngineInterface, restart: Restart, pane: string, now: number): Promise<string | undefined> {
  if (restart.isTurnRunning) return 'a turn is running'
  const activity = await sh($, 'tmux list-clients -t "$1" -F "#{client_activity}"', [pane])
  if (activity === undefined) return 'tmux could not list the clients of its session'
  if (hasLiveClient(activity, now)) return 'a tmux client attached to it was used in the last 10 minutes'
  if ((await $.prompt.read()).text.trim() !== '') return 'the prompt box is not empty'
  if (restart.isTurnRunning) return 'a turn is running'
  return undefined
}

// Says once per target version why a session is not restarting yet
async function hold($: EngineInterface, restart: Restart, target: string, id: string, why: string) {
  if (restart.heldFor !== target) {
    restart.heldFor = target
    restart.held = []
  }
  if (restart.held!.includes(why)) return
  restart.held!.push(why)
  await fluid($, ['log', 'claude', `Not restarting session ${id.slice(0, 8)} to update to ${target} yet: ${why}`])
}

async function restartCheck($: EngineInterface, restart: Restart) {
  const mode = await $.env.get('AUTO_RESTART_TO_UPDATE')
  if (mode !== 'dry' && mode !== 'on') return
  if (!(await isInstalled($))) return
  const now = await $.clock.now()

  // The process environment, which $.env (the settings files) does not see
  const pane = await sh($, 'printf %s "$TMUX_PANE"')
  if (!pane) return

  const claude = await sh($, 'command -v claude')
  if (!claude) return
  const onDisk = parseVersion((await sh($, '"$1" --version', [claude])) ?? '')
  const running = (await $.session.version()).version
  // Only forward: a claude on PATH older than the running one is not an update
  if (onDisk === undefined || !isNewer(onDisk, running)) return

  const id = await $.session.id()
  if (!SESSION_ID.test(id)) return
  // Kept per session: the guard is there to stop one session retrying the same
  // target, not to let one restart hold every other idle session back
  const key = `lastRestart:${id}`
  const last = (await $.store.get(key)) as { target?: string; at?: number } | undefined
  if (last?.target === onDisk && last.at !== undefined && now - last.at < RESTART_RETRY_MS) {
    return hold($, restart, onDisk, id, `it already tried this build at ${stamp(last.at)}`)
  }

  // A backgrounded command or subagent outlives the turn, and a session cron
  // (CronCreate, ScheduleWakeup, /loop) means the session is waiting to be woken:
  // the pane looks idle either way, but the respawn would take the work with it
  const why = restart.isTurnRunning ? 'a turn is running'
    : restart.hasPendingWork ? 'background work is in flight, or it is waiting for a wakeup'
    : now - restart.lastActivity < RESTART_IDLE_MS ? 'it was used in the last 10 minutes'
    : await whyAttended($, restart, pane, now)
  if (why !== undefined) return hold($, restart, onDisk, id, why)

  const cwd = await $.session.cwd()

  if (mode === 'dry') {
    if (restart.loggedFor !== onDisk) {
      restart.loggedFor = onDisk
      $.ui.log(`restart to update (dry): would restart ${running} -> ${onDisk} at ${stamp(now)} in ${pane} as ${claude} -r ${id}${restart.isRemote ? ' --remote-control' : ''}`)
    }
    return
  }

  // Everything that waits comes before the last look, so a turn cannot start
  // between it and the respawn. The record is taken back if it is not made
  await fluid($, ['log', 'claude', `Restarting an idle session in tmux to update, ${running} -> ${onDisk}`])
  await $.store.set(key, { target: onDisk, at: now, from: running, id, isRemote: restart.isRemote === true })
  if ((await whyAttended($, restart, pane, now)) !== undefined || restart.isTurnRunning) {
    await $.store.delete(key)
    void fluid($, ['log', 'claude', 'Someone came back to the session; not restarting it'])
    return
  }

  // The time the check began, seconds ago: asking the clock again would wait
  $.ui.log(`restart to update: ${running} -> ${onDisk} at ${stamp(now)}`)
  // tmux 3.0+ runs the trailing arguments as an argv, so nothing is quoted into
  // a command line. The shell after claude keeps the pane usable if it fails
  await sh($, 'tmux respawn-pane -k -t "$1" -c "$2" sh -c \'if [ "$2" = rc ]; then "$0" -r "$1" --remote-control; else "$0" -r "$1"; fi; exec "${SHELL:-sh}"\' "$3" "$4" "$5"',
    [pane, cwd, claude, id, restart.isRemote ? 'rc' : 'plain'])
}

// One check at a time; a failure is logged to the debug log and dropped, so
// this can do nothing but never stop a session
async function restartTick($: EngineInterface, restart: Restart) {
  if (restart.isChecking) return
  restart.isChecking = true
  try {
    await restartCheck($, restart)
  } catch (err) {
    $.ui.log(`restart to update: check failed: ${String(err)}`, { to: 'debug' })
  } finally {
    restart.isChecking = false
  }
}

async function restartActivity($: EngineInterface, restart: Restart, isTurnRunning: boolean) {
  restart.isTurnRunning = isTurnRunning
  restart.lastActivity = await $.clock.now()
}

async function started($: EngineInterface, state: State) {
  await $.env.set('FLUID_MOD', '1')
  state.limits = (await $.session.usage()).rateLimits
  void observe($, state)
}

export const register: Register = on => {
  const state: State = { limits: [], isTurnRunning: false }
  const restart: Restart = { isTurnRunning: false, lastActivity: 0 }

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    try {
      await restartActivity($, restart, false)
      // A session this restarted with --remote-control keeps it the next time
      const last = (await $.store.get(`lastRestart:${await $.session.id()}`)) as { isRemote?: boolean } | undefined
      if (last?.isRemote) restart.isRemote = true
      restart.ticker?.cancel()
      restart.ticker = $.clock.every(RESTART_CHECK_MS, () => void restartTick($, restart))
    } catch {
      // No ticker: the session runs as if restart to update were off
    }
    await started($, state)
    return result
  })

  // Do not wait for the readings to be handed over: hooks have a time budget
  on('session.measure', ($, e, next) => {
    if (e.changed.includes('rateLimits')) {
      state.limits = e.rateLimits
      void observe($, state)
    }
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      await restartActivity($, restart, true).catch(() => {})
      await turnStarted($, state)
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) {
      await restartActivity($, restart, false).catch(() => {})
      state.isTurnRunning = false
      // The continue sent got as far as an answer: resumed
      if (state.pending?.sentAt !== undefined && e.reason === 'answer') stopWatching(state)
      // Ended in an error with a window used up: stopped on a limit
      if (e.reason === 'error' && isLimited((await $.session.usage()).rateLimits)) await stopped($, state)
    }
    return result
  })

  // Look-only: a prompt from a phone or the web, or /remote-control at the
  // terminal, means a restart should bring Remote Control back.
  // ponytail: once seen it stays for the session; read Remote Control's own
  // state instead if the engine ever exposes one
  on('prompt.submit', (_$, e, next) => {
    if (e.origin?.kind === 'bridge') restart.isRemote = true
    return next(e)
  })
  on('command.run', (_$, e, next) => {
    if (e.command === 'remote-control') restart.isRemote = true
    return next(e)
  })

  // Look-only hook: Stop brings the background work still running and anything planned
  // to wake this session later. Once they end, the next turn's Stop puts it right
  on('classic.Stop', async ($, e, next) => {
    const result = await next(e)
    if (e.agent_id === undefined) {
      restart.hasPendingWork = (e.background_tasks?.length ?? 0) + (e.session_crons?.length ?? 0) > 0
    }
    return result
  }).catch(($, e, next) => next(e))

  // Look-only hook: even when this fails, StopFailure goes ahead
  on('classic.StopFailure', async ($, e, next) => {
    const result = await next(e)
    if (e.error === 'rate_limit' && e.agent_id === undefined) await stopped($, state)
    return result
  }).catch(($, e, next) => next(e))

  on('session.end', ($, e, next) => {
    restart.ticker?.cancel()
    restart.ticker = undefined
    stopWatching(state)
    return next(e)
  })
}
