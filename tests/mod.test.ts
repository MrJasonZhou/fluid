// Fluid のフック・モジュール（hooks/register.ts）のテスト。
//
//   claude plugin test .
//
// エンジンの下に置いたフックが、HOME、時計、fluid.sh の呼び出し、使用量、
// 入力欄、送られたプロンプトを受け持つ。本物の fluid.sh は動かさない。

import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, SessionRateLimit } from 'claude-code'
import { GRACE_MS, MAX_ATTEMPTS, NOTIFY_RETRY_MS, RESTART_CHECK_MS, RESTART_IDLE_MS, TICK_MS, VERIFY_MS, isNewer, parseVersion, stamp, resetAt, toReading } from '../hooks/register'

const T0 = Date.parse('2026-10-15T00:00:00Z')
const BIN = '/home/u/.fluid/fluid.sh'
const ID = '0f8b5c2e-1234-4abc-9def-0123456789ab'

type World = {
  // fluid.sh に渡した引数と標準入力
  runs: { argv: string[]; stdin?: string }[]
  // 送られたプロンプト
  submitted: string[]
  env: Record<string, string | undefined>
  limits: SessionRateLimit[]
  draft: string
  clock: ReturnType<typeof mock.clock>
  // 入力欄が読まれるたびに、答える前に呼ばれる
  onRead?: () => Promise<void>
  // プロンプトが送られるたびに、答える前に呼ばれる
  onSubmit?: () => Promise<void>
  // この回数だけ、通知に失敗する
  failNotify: number
  // ~/.fluid/fluid.sh があるか（/fluid:install の後か）
  isInstalled: boolean
  // session.id が答える値。セッション別の記録を試すために変えられる
  sessionId: string
  // What the shell scripts of restart to update see: the pane, the claude on
  // disk and how many clients are attached
  tmux: { pane: string; onDisk: string; attached: string }
  // The prompts of the scripts run with sh -c
  scripts: string[]
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

// エンジンの下の世界。どのイベントも、ここが最後に答える
function world(on: On, limits: SessionRateLimit[] = [], env: Record<string, string> = {}): World {
  const w: World = {
    runs: [], submitted: [], env: {}, limits, draft: '', isInstalled: true, failNotify: 0, sessionId: ID, clock: mock.clock(on, { now: T0 }),
    tmux: { pane: '', onDisk: '2.1.300', attached: '0' }, scripts: [], logs: [],
  }

  mock.env(on, { HOME: '/home/u', ...env })
  mock.store(on)
  on('env.set', (_$, e) => {
    w.env[e.name] = e.value
    return { value: undefined }
  })
  on('process.run', (_$, e) => {
    if (e.argv[0] === 'sh') {
      const script = e.argv[2] ?? ''
      w.scripts.push(script)
      const stdout = script.includes('TMUX_PANE') ? w.tmux.pane
        : script.includes('command -v') ? '/usr/bin/claude'
        : script.includes('--version') ? `${w.tmux.onDisk} (Claude Code)`
        : script.includes('session_attached') ? w.tmux.attached
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
    // 長い窓が埋まって開く時刻が分からない: 短い窓の時刻で送っても止まるだけ
    const unknown = full.map(l => (l.kind === 'seven_day' ? { kind: l.kind, percentUsed: 100 } : l))
    expect(resetAt(unknown, T0)).toBe(undefined)
  })

  test('session start marks the session and hands its reading to fluid.sh', async ($, on) => {
    const w = world(on, limitsAt(T0, 12, 3_600_000))
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // 受け渡しはフックの後ろで続く。走り始めたものを終わらせる
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

    // 入力欄を読んでいる最中に、人かエージェント自身が続ける
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

    // 送られた直後に、そのターンが始まってまた上限に当たる
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

    // 入力欄の読み取りが長引き、送った continue のターンはその送信の中で始まる
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

    // 入力欄の読み取りが一周期より長くかかる
    w.onRead = () => w.clock.sleep(TICK_MS + 5_000)
    await w.clock.advance(RESET_IN + GRACE_MS + 4 * TICK_MS)
    expect(w.submitted).toEqual(['continue'])
  })
})

describe('restart to update', () => {
  const NEWER = { pane: '%3', onDisk: '2.1.306', attached: '0' }
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
    // 同じ版へ二度は上げない。ただしそれは、このセッションの話
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
    // 別のセッションは、その記録に縛られない
    w.sessionId = '1a2b3c4d-5678-4abc-9def-abcdef012345'
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(2)
  })

  test('background work still in flight holds the session', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // ターンは終わったが、背景のシェルはまだ走っている
    await $.classic.Stop({ background_tasks: [{ id: 'b1', type: 'shell', status: 'running', description: 'npm run build' }] })
    await w.clock.advance(IDLE)
    expect(respawns(w)).toEqual([])
    // 仕事が終われば、次の Stop がそう言う
    await $.classic.Stop({ background_tasks: [] })
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
  })

  test('a wakeup it is waiting for holds the session', async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // /loop の途中: 背景の仕事はないが、自分で予約した起床を待っている
    await $.classic.Stop({ session_crons: [{ id: 'c1', schedule: '*/20 * * * *', recurring: true, prompt: 'check CI' }] })
    await w.clock.advance(IDLE)
    expect(respawns(w)).toEqual([])
    // 予定がなくなれば、普通の空いたセッション
    await $.classic.Stop({ session_crons: [] })
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
  })

  test("a subagent's own Stop does not speak for the session", async ($, on) => {
    const w = world(on, [], { AUTO_RESTART_TO_UPDATE: 'on' })
    w.tmux = { ...NEWER }
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    // 子エージェントの Stop は、親のセッションの話ではない
    await $.classic.Stop({ agent_id: 'sub-1', background_tasks: [{ id: 'b2', type: 'subagent', status: 'running', description: 'review' }], session_crons: [] })
    await w.clock.advance(IDLE)
    expect(respawns(w).length).toBe(1)
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
      () => { w.tmux = { ...NEWER, attached: '1' } },
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
      if (argv[1] === 'log' && /Restarting/.test(argv[3] ?? '')) w.tmux.attached = '1'
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
