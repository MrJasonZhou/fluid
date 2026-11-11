// Tests for Fluid's hooks module (hooks/register.ts).
//
//   claude plugin test .
//
// Hooks placed under the engine stand in for HOME, the clock, calls to fluid.sh, usage,
// the prompt box and sent prompts. The real fluid.sh never runs.

import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, SessionRateLimit } from 'claude-code'
import { GRACE_MS, MAX_ATTEMPTS, NOTIFY_RETRY_MS, RESTART_CHECK_MS, RESTART_IDLE_MS, RESTART_STUCK_MS, TICK_MS, VERIFY_MS, hasLiveClient, isNewer, parseVersion, stamp, resetAt, toReading } from '../hooks/register'

const T0 = Date.parse('2026-10-15T00:00:00Z')
const BIN = '/home/u/.fluid/fluid.sh'
const ID = '0f8b5c2e-1234-4abc-9def-0123456789ab'

type World = {
  // Arguments and stdin passed to fluid.sh
  runs: { argv: string[]; stdin?: string }[]
  // Prompts that were sent
  submitted: string[]
  env: Record<string, string | undefined>
  limits: SessionRateLimit[]
  draft: string
  clock: ReturnType<typeof mock.clock>
  // Called each time the prompt box is read, before answering
  onRead?: () => Promise<void>
  // A shell script containing this is refused, so the call rejects
  denyScript?: string
  // Called each time a prompt is sent, before answering
  onSubmit?: () => Promise<void>
  // Fail this many notifications
  failNotify: number
  // Whether ~/.fluid/fluid.sh exists (after /fluid:install)
  isInstalled: boolean
  // What session.id answers. Changeable to test per-session records
  sessionId: string
  // What the shell scripts of restart to update see: the pane, the claude on
  // disk and the last keypress (epoch seconds) of each attached client
  tmux: { pane: string; onDisk: string; clients: string }
  // The prompts of the scripts run with sh -c, and the arguments of each
  scripts: string[]
  scriptArgs: string[][]
  // Called with each fluid.sh call, before it is answered
  onRun?: (argv: string[]) => void
  logs: string[]
}

function limitsAt(now: number, used: number, resetInMs: number): SessionRateLimit[] {
  return [
    { kind: 'five_hour', percentUsed: used, resetsAt: new Date(now + resetInMs).toISOString() },
    { kind: 'seven_day', percentUsed: 40, resetsAt: new Date(now + 3 * 86_400_000).toISOString() },
  ]
}

// The world under the engine. Every event is answered here last
function world(on: On, limits: SessionRateLimit[] = [], env: Record<string, string> = {}, stored: Record<string, unknown> = {}): World {
  const w: World = {
    runs: [], submitted: [], env: {}, limits, draft: '', isInstalled: true, failNotify: 0, sessionId: ID, clock: mock.clock(on, { now: T0 }),
    tmux: { pane: '', onDisk: '2.1.300', clients: '' }, scripts: [], scriptArgs: [], logs: [],
  }

  mock.env(on, { HOME: '/home/u', ...env })
  mock.store(on, stored)
  on('env.set', (_$, e) => {
    w.env[e.name] = e.value
    return { value: undefined }
  })
  on('process.run', (_$, e) => {
    if (e.argv[0] === 'sh') {
      const script = e.argv[2] ?? ''
      if (w.denyScript !== undefined && script.includes(w.denyScript)) return { deny: 'boom' }
      w.scripts.push(script)
      w.scriptArgs.push(e.argv.slice(4))
      const stdout = script.includes('TMUX_PANE') ? w.tmux.pane
        : script.includes('command -v') ? '/usr/bin/claude'
        : script.includes('--version') ? `${w.tmux.onDisk} (Claude Code)`
        : script.includes('list-clients') ? w.tmux.clients
        : ''
      return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    w.runs.push({ argv: [...e.argv], stdin: e.init?.stdin })
    w.onRun?.([...e.argv])
    const isFailing = e.argv[1] === 'notify' && w.failNotify > 0
    if (isFailing) w.failNotify -= 1
    return { value: { exitCode: isFailing ? 1 : 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.exists', (_$, e) => ({ value: e.path === BIN && w.isInstalled }))
  on('session.usage', () => ({ value: { startedAt: T0, context: { window: 200_000 }, rateLimits: w.limits } }))
  on('prompt.read', async () => {
    await w.onRead?.()
    return { value: { text: w.draft, cursor: w.draft.length } }
  })
  on('prompt.submit', async (_$, e) => {
    w.submitted.push(e.text)
    await w.onSubmit?.()
    return { text: e.text }
  })

  on('session.version', () => ({ value: { version: '2.1.300', base: '2.1.300' } }))
  on('session.id', () => ({ value: w.sessionId }))
  on('session.cwd', () => ({ value: '/work' }))
  on('ui.log', (_$, e) => {
    w.logs.push(e.text)
    return { value: undefined }
  })

  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('classic.Stop', () => ({}))
  on('classic.StopFailure', () => ({}))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('command.run', () => ({ text: '' }))

  return w
}

const observed = (w: World) => w.runs.filter(r => r.argv[1] === 'observe')
const notified = (w: World) => w.runs.filter(r => r.argv[1] === 'notify')

describe('readings', () => {
  test('converts to the status line shape, resets in epoch seconds', () => {
    const reading = toReading(limitsAt(T0, 37.5, 3_600_000))
    expect(reading).toEqual({
      rate_limits: {
        five_hour: { used_percentage: 37.5, resets_at: T0 / 1000 + 3600 },
        seven_day: { used_percentage: 40, resets_at: T0 / 1000 + 3 * 86_400 },
      },
    })
    expect(toReading([])).toBe(undefined)
    expect(toReading([{ kind: 'spend_limit', percentUsed: 3 }])).toBe(undefined)
  })

  test('the reset that matters: the long window when it is full', () => {
    const limits = limitsAt(T0, 100, 600_000)
    expect(resetAt(limits, T0)).toBe(T0 + 600_000)
    const full = limits.map(l => (l.kind === 'seven_day' ? { ...l, percentUsed: 100 } : l))
    expect(resetAt(full, T0)).toBe(T0 + 3 * 86_400_000)
    expect(resetAt([], T0)).toBe(undefined)
    // The long window is full with no known opening time: sending at the short window's time would only stop again
    const unknown = full.map(l => (l.kind === 'seven_day' ? { kind: l.kind, percentUsed: 100 } : l))
    expect(resetAt(unknown, T0)).toBe(undefined)
  })

  test('session start marks the session and hands its reading to fluid.sh', async ($, on) => {
    const w = world(on, limitsAt(T0, 12, 3_600_000))
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // Handing over continues after the hook. Let what started finish
    await w.clock.advance(0)

    expect(w.env.FLUID_MOD).toBe('1')
    expect(observed(w).length).toBe(1)
    expect(observed(w)[0]?.argv).toEqual([BIN, 'observe', 'claude', 'mod'])
    expect(JSON.parse(observed(w)[0]?.stdin ?? '{}').rate_limits.five_hour.used_percentage).toBe(12)
  })

  test('a measure hands over a moved rate limit, and nothing else', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    expect(observed(w).length).toBe(0)

    await $.session.measure({ context: { window: 200_000 }, rateLimits: limitsAt(T0, 20, 3_600_000), changed: ['rateLimits'] })
    await $.session.measure({ context: { window: 200_000, percent: 9 }, rateLimits: limitsAt(T0, 20, 3_600_000), changed: ['context'] })
    await w.clock.advance(0)
    expect(observed(w).length).toBe(1)
  })

  test('no subscription, no reading', async ($, on) => {
    const w = world(on, [])
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await $.session.measure({ context: { window: 200_000 }, rateLimits: [], changed: ['rateLimits'] })
    await w.clock.advance(0)
    expect(observed(w).length).toBe(0)
  })
})

describe('resume', () => {
  const RESET_IN = 60_000

  async function hitLimit($: Engine, w: World) {
    w.limits = limitsAt(w.clock.now(), 100, RESET_IN)
    await $.classic.StopFailure({ error: 'rate_limit' })
  }

  test('continues a session nobody picked up, after the reset and the grace', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    await w.clock.advance(RESET_IN + GRACE_MS - TICK_MS)
    expect(w.submitted).toEqual([])

    await w.clock.advance(2 * TICK_MS)
    expect(w.submitted).toEqual(['continue'])
  })

  test('leaves it alone when the agent continued by itself', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    await w.clock.advance(RESET_IN + 10_000)
    await $.turn.start({ text: 'continue', turnId: 't-own' })
    await w.clock.advance(GRACE_MS + TICK_MS)
    expect(w.submitted).toEqual([])
  })

  test('sends nothing when a turn starts while it is looking at the box', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    // While the prompt box is being read, a person or the agent itself carries on
    let started = false
    w.onRead = async () => {
      if (started) return
      started = true
      await $.turn.start({ text: 'my own prompt', turnId: 't-race' })
    }
    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)
    await w.clock.advance(10 * TICK_MS)
    expect(started).toBe(true)
    expect(w.submitted).toEqual([])
  })

  test('leaves it to whoever is typing in the box', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    w.draft = 'half a sente'
    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)
    expect(w.submitted).toEqual([])

    w.draft = ''
    await w.clock.advance(10 * TICK_MS)
    expect(w.submitted).toEqual([])
  })

  test('stops once the continue it sent is answered', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)
    await $.turn.start({ text: 'continue', turnId: 't1' })
    await $.turn.complete({ answer: 'done', durationMs: 5, isAborted: false, turnId: 't1', reason: 'answer' })
    await w.clock.advance(VERIFY_MS + 10 * TICK_MS)
    expect(w.submitted).toEqual(['continue'])
  })

  test(`gives up after ${MAX_ATTEMPTS} tries and says so`, async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    // Right after the send, that turn starts and hits the limit again
    for (let i = 0; i < MAX_ATTEMPTS; i++) {
      for (let k = 0; k < 100 && w.submitted.length <= i; k++) await w.clock.advance(TICK_MS)
      await $.turn.start({ text: 'continue', turnId: `t${i}` })
      await hitLimit($, w)
    }
    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)

    expect(w.submitted.length).toBe(MAX_ATTEMPTS)
    expect(notified(w).length).toBe(1)
    expect(notified(w)[0]?.argv.slice(1, 3)).toEqual(['notify', 'resume-failed'])
  })

  test('a slow look at the box still knows the turn it started as its own', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    // Reading the prompt box drags on, and the turn of the continue sent starts within that send
    w.onRead = () => w.clock.sleep(15_000)
    w.onSubmit = async () => {
      await $.turn.start({ text: 'continue', turnId: `t${w.submitted.length}` })
    }
    for (let i = 0; i < MAX_ATTEMPTS; i++) {
      for (let k = 0; k < 100 && w.submitted.length <= i; k++) await w.clock.advance(TICK_MS)
      await hitLimit($, w)
    }
    await w.clock.advance(RESET_IN + GRACE_MS + 2 * TICK_MS)

    expect(w.submitted.length).toBe(MAX_ATTEMPTS)
    expect(notified(w).length).toBe(1)
  })

  test('says it gave up again until that goes out', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)
    w.failNotify = 1

    for (let i = 0; i < MAX_ATTEMPTS; i++) {
      for (let k = 0; k < 100 && w.submitted.length <= i; k++) await w.clock.advance(TICK_MS)
      await $.turn.start({ text: 'continue', turnId: `t${i}` })
      await hitLimit($, w)
    }
    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)
    expect(notified(w).length).toBe(1)

    await w.clock.advance(NOTIFY_RETRY_MS + TICK_MS)
    expect(notified(w).length).toBe(2)
    await w.clock.advance(3 * NOTIFY_RETRY_MS)
    expect(notified(w).length).toBe(2)
  })

  test('a turn that ended in an error with the window used up counts as a stop', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    w.limits = limitsAt(T0, 100, RESET_IN)
    await $.turn.start({ text: 'go', turnId: 't1' })
    await $.turn.complete({ answer: '', durationMs: 5, isAborted: false, turnId: 't1', reason: 'error' })

    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)
    expect(w.submitted).toEqual(['continue'])
  })

  test('another error, with room left, is not a stop', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    w.limits = limitsAt(T0, 50, RESET_IN)
    await $.turn.start({ text: 'go', turnId: 't1' })
    await $.turn.complete({ answer: '', durationMs: 5, isAborted: false, turnId: 't1', reason: 'error' })

    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)
    expect(w.submitted).toEqual([])
  })

  test('a subagent hitting the limit is not the session stopping', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    w.limits = limitsAt(T0, 100, RESET_IN)
    await $.classic.StopFailure({ error: 'rate_limit', agent_id: 'sub-1' })

    await w.clock.advance(RESET_IN + GRACE_MS + TICK_MS)
    expect(w.submitted).toEqual([])
  })

  test('the plugin alone, without /fluid:install, sends nothing', async ($, on) => {
    const w = world(on)
    w.isInstalled = false
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    await w.clock.advance(RESET_IN + GRACE_MS + 10 * TICK_MS)
    expect(w.submitted).toEqual([])
  })

  test('uninstalled while waiting: sends nothing', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    await w.clock.advance(RESET_IN)
    w.isInstalled = false
    await w.clock.advance(GRACE_MS + 10 * TICK_MS)
    expect(w.submitted).toEqual([])
  })

  test('a stop with no usage window to wait for (an API key, a gateway) is left alone', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    w.limits = []
    await $.classic.StopFailure({ error: 'rate_limit' })

    await w.clock.advance(GRACE_MS + 20 * TICK_MS)
    expect(w.submitted).toEqual([])
    expect(w.runs.some(r => r.argv[1] === 'log' && /no usage window/.test(r.argv[3] ?? ''))).toBe(true)
  })

  test('a look that outlasts its period does not overlap the next one', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await hitLimit($, w)

    // Reading the prompt box takes longer than one tick
    w.onRead = () => w.clock.sleep(TICK_MS + 5_000)
    await w.clock.advance(RESET_IN + GRACE_MS + 4 * TICK_MS)
    expect(w.submitted).toEqual(['continue'])
  })
})

describe('restart to update', () => {
  const NEWER = { pane: '%3', onDisk: '2.1.306', clients: '' }
  // A client that just typed, and one silent since long before the session started
  const LIVE = '9999999999'
  const STALE = String(Math.floor(T0 / 1000) - 3600)
  const IDLE = RESTART_IDLE_MS + RESTART_CHECK_MS
  const respawns = (w: World) => w.scripts.filter(s => s.includes('respawn-pane'))

  async function idle($: Engine, w: World, ms = IDLE) {
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await w.clock.advance(ms)
  }

  test('reads the version claude --version prints', () => {
    expect(parseVersion('2.1.306 (Claude Code)')).toBe('2.1.306')
    expect(parseVersion('2.1.280-dev.20260920.t101500.sha1a2b3c4')).toBe('2.1.280-dev.20260920.t101500.sha1a2b3c4')
    expect(parseVersion('command not found')).toBe(undefined)
  })

  test('stamps the local date and time to the minute', () => {
    const d = new Date(2026, 9, 6, 4, 5, 59)
    expect(stamp(d.getTime())).toBe('2026-10-06 04:05')
  })

  test('only a later release counts as an update', () => {
    expect(isNewer('2.1.306', '2.1.300')).toBe(true)
    expect(isNewer('2.2.0', '2.1.999')).toBe(true)
    expect(isNewer('2.1.10', '2.1.9')).toBe(true)
    expect(isNewer('2.1.300', '2.1.306')).toBe(false)
    expect(isNewer('2.1.300', '2.1.300')).toBe(false)
    expect(isNewer('2.1.300-dev.20260920', '2.1.300')).toBe(false)
    expect(isNewer('garbage', '2.1.300')).toBe(false)
  })

  test('a client counts as there only if it typed within the idle window', () => {
    const now = 1_000_000_000_000
    const s = (ms: number) => String(Math.floor((now - ms) / 1000))
    expect(hasLiveClient('', now)).toBe(false)
    expect(hasLiveClient(s(RESTART_IDLE_MS + 60_000), now)).toBe(false)
    expect(hasLiveClient(`${s(RESTART_IDLE_MS + 60_000)}\n${s(60_000)}`, now)).toBe(true)
    // Anything it cannot read is taken as someone there
    expect(hasLiveClient('garbage', now)).toBe(true)
  })

  test('off by default: runs nothing at all', async ($, on) => {
    const w = world(on)
    w.tmux = { ...NEWER }
    await idle($, w)
    expect(w.scripts).toEqual([])
  })

  test('restarts an idle, detached session in tmux once per build', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await idle($, w, IDLE + 10 * RESTART_CHECK_MS)
    expect(respawns(w).length).toBe(1)
    expect(w.runs.some(r => r.argv[1] === 'log' && /Restarting an idle session/.test(r.argv[3] ?? ''))).toBe(true)
    expect(w.logs.some(l => /^restart to update: 2\.1\.300 -> 2\.1\.306 at \d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(l))).toBe(true)
  })

  test('once per build is per session: another idle session still gets its restart', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await idle($, w)
    expect(respawns(w).length).toBe(1)
    // Never update to the same build twice. But that is this session's record
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
    // Another session is not bound by it
    w.sessionId = '1a2b3c4d-5678-4abc-9def-abcdef012345'
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(2)
  })

  test('background work still in flight holds the session', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // The turn has ended but a background shell is still running
    await $.classic.Stop({ background_tasks: [{ id: 'b1', type: 'shell', status: 'running', description: 'npm run build' }] })
    await w.clock.advance(IDLE)
    expect(respawns(w)).toEqual([])
    // Once the work is done, the next Stop says so
    await $.classic.Stop({ background_tasks: [] })
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
  })

  test('a wakeup it is waiting for holds the session', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // In the middle of /loop: no background work, but waiting on a wakeup it booked itself
    await $.classic.Stop({ session_crons: [{ id: 'c1', schedule: '*/20 * * * *', recurring: true, prompt: 'check CI' }] })
    await w.clock.advance(IDLE)
    expect(respawns(w)).toEqual([])
    // With nothing planned, an ordinary idle session
    await $.classic.Stop({ session_crons: [] })
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
  })

  test("a subagent's own Stop does not speak for the session", async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // A subagent's Stop is not about the parent session
    await $.classic.Stop({ agent_id: 'sub-1', background_tasks: [{ id: 'b2', type: 'subagent', status: 'running', description: 'review' }], session_crons: [] })
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
  })

  test('a client attached but silent since before the idle window does not hold it', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER, clients: STALE }
    await idle($, w)
    expect(respawns(w).length).toBe(1)
  })

  test('says once per build why a session is not restarting, and nothing without an update', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    const held = () => w.runs.filter(r => r.argv[1] === 'log' && /^Not restarting session/.test(r.argv[3] ?? '')).map(r => r.argv[3])
    w.tmux = { ...NEWER, onDisk: '2.1.300' }
    await idle($, w, IDLE + 3 * RESTART_CHECK_MS)
    expect(held()).toEqual([])
    w.tmux = { ...NEWER, clients: LIVE }
    await w.clock.advance(4 * RESTART_CHECK_MS)
    expect(held()).toEqual([`Not restarting session ${ID.slice(0, 8)} to update to 2.1.306 yet: a tmux client attached to it was used in the last 10 minutes`])
    w.tmux = { ...NEWER }
    w.draft = 'half a thought'
    await w.clock.advance(2 * RESTART_CHECK_MS)
    expect(held().length).toBe(2)
    expect(held()[1]).toMatch(/the prompt box is not empty$/)
    expect(respawns(w)).toEqual([])
  })

  test('a check that fails says so in the log, once until one gets through', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    const said = () => w.runs.filter(r => r.argv[1] === 'log' && /^Restart to update:/.test(r.argv[3] ?? '')).map(r => r.argv[3])
    w.tmux = { ...NEWER }
    w.denyScript = 'list-clients'
    await idle($, w, IDLE + 3 * RESTART_CHECK_MS)
    expect(said().length).toBe(1)
    expect(said()[0]).toMatch(/^Restart to update: a check failed: .*boom/)
    expect(respawns(w)).toEqual([])
    w.denyScript = undefined
    await w.clock.advance(RESTART_CHECK_MS)
    expect(respawns(w).length).toBe(1)
  })

  test('a check that never returns does not stop the ones after it', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    const said = () => w.runs.filter(r => r.argv[1] === 'log' && /^Restart to update:/.test(r.argv[3] ?? '')).map(r => r.argv[3])
    w.tmux = { ...NEWER }
    w.onRead = () => new Promise<void>(() => {})
    await idle($, w)
    expect(RESTART_STUCK_MS).toBeLessThan(RESTART_CHECK_MS)
    w.onRead = undefined
    await w.clock.advance(RESTART_CHECK_MS)
    expect(said()).toEqual(['Restart to update: a check never finished; starting over'])
    expect(respawns(w).length).toBe(1)
  })

  test('a session that took a Remote Control prompt comes back with Remote Control', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await $.prompt.submit({ text: 'hi from the phone', wait: false, origin: { kind: 'bridge' } })
    await w.clock.advance(IDLE)
    const i = w.scripts.findIndex(s => s.includes('respawn-pane'))
    expect(w.scripts[i]).toContain('--remote-control')
    expect(w.scriptArgs[i]).toEqual(['%3', '/work', '/usr/bin/claude', ID, 'rc'])
  })

  test('/remote-control at the terminal counts too, a plain session does not', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    const last = () => w.scriptArgs[w.scripts.map(s => s.includes('respawn-pane')).lastIndexOf(true)]
    await w.clock.advance(IDLE)
    expect(last()?.[4]).toBe('plain')
    w.sessionId = '1a2b3c4d-5678-4abc-9def-abcdef012345'
    await $.command.run({ command: 'remote-control', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } })
    await w.clock.advance(IDLE)
    expect(last()?.[4]).toBe('rc')
  })

  test('a session restarted with Remote Control keeps it the next time', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' }, { [`lastRestart:${ID}`]: { target: '2.1.300', at: T0, isRemote: true } })
    w.tmux = { ...NEWER }
    await idle($, w)
    expect(w.scriptArgs[w.scripts.findIndex(s => s.includes('respawn-pane'))]?.[4]).toBe('rc')
  })

  test('dry only says what it would do, once', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'dry' })
    w.tmux = { ...NEWER }
    await idle($, w, IDLE + 10 * RESTART_CHECK_MS)
    expect(respawns(w)).toEqual([])
    expect(w.logs.filter(l => l.includes('would restart')).length).toBe(1)
  })

  test('leaves the session alone when anything says someone is there, or the build is not newer', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    const cases: (() => void)[] = [
      () => { w.tmux = { ...NEWER, clients: LIVE } },
      () => { w.tmux = { ...NEWER, clients: `${STALE}\n${LIVE}` } },
      () => { w.tmux = { ...NEWER }; w.draft = 'half a thought' },
      () => { w.tmux = { ...NEWER, pane: '' } },
      () => { w.tmux = { ...NEWER, onDisk: '2.1.300' } },
      () => { w.tmux = { ...NEWER, onDisk: '2.1.299' } },
      () => { w.tmux = { ...NEWER }; w.isInstalled = false },
    ]
    for (const set of cases) {
      w.draft = ''
      w.isInstalled = true
      set()
      await w.clock.advance(IDLE)
    }
    expect(respawns(w)).toEqual([])
  })

  test('someone coming back while it logs keeps the session', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    // The log call before the last look: a person attaches meanwhile
    w.onRun = argv => {
      if (argv[1] === 'log' && /Restarting/.test(argv[3] ?? '')) w.tmux.clients = LIVE
    }
    await idle($, w)
    expect(respawns(w)).toEqual([])
    expect(w.runs.some(r => r.argv[1] === 'log' && /came back/.test(r.argv[3] ?? ''))).toBe(true)
  })

  test('a running turn, or one that just ended, holds it back', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await $.turn.start({ text: 'go', turnId: 't1' })
    await w.clock.advance(IDLE)
    expect(respawns(w)).toEqual([])

    await $.turn.complete({ answer: 'done', durationMs: 5, isAborted: false, turnId: 't1', reason: 'answer' })
    await w.clock.advance(RESTART_IDLE_MS - RESTART_CHECK_MS)
    expect(respawns(w)).toEqual([])
    await w.clock.advance(2 * RESTART_CHECK_MS)
    expect(respawns(w).length).toBe(1)
  })
})
