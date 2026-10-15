// Fluid のフック・モジュール（hooks/register.ts）のテスト。
//
//   claude plugin test .
//
// エンジンの下に置いたフックが、HOME、時計、fluid.sh の呼び出し、使用量、
// 入力欄、送られたプロンプトを受け持つ。本物の fluid.sh は動かさない。

import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, SessionRateLimit } from 'claude-code'
import { GRACE_MS, MAX_ATTEMPTS, TICK_MS, VERIFY_MS, resetAt, toReading } from '../hooks/register'

const T0 = Date.parse('2026-10-15T00:00:00Z')
const BIN = '/home/u/.fluid/fluid.sh'

type World = {
  // fluid.sh に渡した引数と標準入力
  runs: { argv: string[]; stdin?: string }[]
  // 送られたプロンプト
  submitted: string[]
  env: Record<string, string | undefined>
  limits: SessionRateLimit[]
  draft: string
  clock: ReturnType<typeof mock.clock>
}

function limitsAt(now: number, used: number, resetInMs: number): SessionRateLimit[] {
  return [
    { kind: 'five_hour', percentUsed: used, resetsAt: new Date(now + resetInMs).toISOString() },
    { kind: 'seven_day', percentUsed: 40, resetsAt: new Date(now + 3 * 86_400_000).toISOString() },
  ]
}

// エンジンの下の世界。どのイベントも、ここが最後に答える
function world(on: On, limits: SessionRateLimit[] = []): World {
  const w: World = { runs: [], submitted: [], env: {}, limits, draft: '', clock: mock.clock(on, { now: T0 }) }

  mock.env(on, { HOME: '/home/u' })
  on('env.set', (_$, e) => {
    w.env[e.name] = e.value
    return { value: undefined }
  })
  on('process.run', (_$, e) => {
    w.runs.push({ argv: [...e.argv], stdin: e.init?.stdin })
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.usage', () => ({ value: { startedAt: T0, context: { window: 200_000 }, rateLimits: w.limits } }))
  on('prompt.read', () => ({ value: { text: w.draft, cursor: w.draft.length } }))
  on('prompt.submit', (_$, e) => {
    w.submitted.push(e.text)
    return { text: e.text }
  })

  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
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
})
