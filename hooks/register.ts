// Fluid - enhancements for coding agents
// Copyright (C) 2026 Jason Zhou
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

// Claude Code の中で動くフック・モジュール。状態栏を包まずに使用量の読み取りを
// fluid.sh へ渡し、上限で止まったセッションをプロセスの中から再開させる。
// どの設定ファイルにも手を付けない。
//
// このモジュールが読み込まれたセッションでは FLUID_MOD=1 を立てる。そこから
// 起動される /fluid:install と StopFailure フックはそれを見て、状態栏を包むことと
// tmux 経由の再開を、このモジュールに任せる。

import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

// fluid.sh の RESUME_GRACE と同じ: リセットの後、エージェント自身の続行に先を譲る時間
export const GRACE_MS = 180_000
// continue を送ってから、効いたかどうかを見るまでの時間
export const VERIFY_MS = 90_000
// 送っても止まったままなら、この回数であきらめて知らせる
export const MAX_ATTEMPTS = 2
// 待っている間の見回りの間隔。スリープから覚めても次の見回りで追いつく
export const TICK_MS = 30_000
// 自分が送った continue で始まったターンを、他人のものと取り違えない幅
const OWN_TURN_MS = 10_000

type Reading = {
  rate_limits: Record<string, { used_percentage: number; resets_at?: number }>
}

type Pending = {
  // 次に見る時刻
  dueAt: number
  // 送った回数
  attempts: number
  // 最後に送った時刻
  sentAt?: number
}

// セッションの間だけ持つ状態。モジュールが読み直されれば初めからになる
type State = {
  limits: readonly SessionRateLimit[]
  pending?: Pending
  isTurnRunning: boolean
  ticker?: { cancel: () => void }
}

// Claude Code の rateLimits を、状態栏が渡す JSON と同じ形にする。fluid.sh の
// claude_parse_limits はそのまま読める
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

// どれかの窓が使い切られているか。組織が管理する Claude Code では StopFailure が
// 入れたプラグインに届かないので、エラーで終わったターンをこれで見分ける
export function isLimited(limits: readonly SessionRateLimit[]): boolean {
  return limits.some(l => (l.kind === 'five_hour' || l.kind === 'seven_day') && l.percentUsed >= 99.9)
}

// 止めた窓が開く時刻（ミリ秒）。長い窓が埋まっていればそちら、なければ短い窓
export function resetAt(limits: readonly SessionRateLimit[], now: number): number | undefined {
  const at = (kind: string) => {
    const limit = limits.find(l => l.kind === kind)
    const t = limit?.resetsAt === undefined ? NaN : Date.parse(limit.resetsAt)
    return Number.isNaN(t) || t <= now ? undefined : { t, isFull: (limit?.percentUsed ?? 0) >= 99.9 }
  }

  const long = at('seven_day')
  if (long?.isFull) return long.t
  return at('five_hour')?.t
}

// fluid.sh を一度呼ぶ。入っていなければ（/fluid:install の前）何もしない
async function fluid($: EngineInterface, args: string[], stdin?: string) {
  const home = await $.env.get('HOME')
  if (home === undefined) return
  try {
    // at への書き込みの途中で止めると、半端なジョブが残る（0.2.3）。待つのは
    // フックではないので、余裕を持たせる
    await $.process.run([`${home}/.fluid/fluid.sh`, ...args], { cwd: '/', stdin, timeoutMs: 60_000 })
  } catch {
    // 未インストール、または一時的な失敗。次の読み取りがまた届く
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

// 待っている再開の見回り
async function tick($: EngineInterface, state: State) {
  const pending = state.pending
  if (pending === undefined) return stopWatching(state)

  const now = await $.clock.now()
  if (now < pending.dueAt || state.isTurnRunning) return

  if (pending.attempts >= MAX_ATTEMPTS) {
    stopWatching(state)
    await fluid($, ['notify', 'resume-failed',
      `Claude Code did not continue a session after its usage limit reset, and neither did Fluid after ${pending.attempts} tries. It is waiting for you.`])
    return
  }

  // 入力欄に書きかけがあれば、誰かがそこにいる。混ぜて送らずに任せる
  const box = await $.prompt.read()
  if (box.text.trim() !== '') {
    stopWatching(state)
    await fluid($, ['log', 'claude', 'Someone is typing in the stopped session; leaving it to them'])
    return
  }

  pending.attempts += 1
  pending.sentAt = now
  pending.dueAt = now + VERIFY_MS
  await fluid($, ['log', 'claude', `Sending continue to the stopped session, attempt ${pending.attempts}`])
  await $.prompt.submit({ text: 'continue', asUser: true })
}

// 上限で止まった: リセットとその後の猶予を待って見回る
async function stopped($: EngineInterface, state: State) {
  const now = await $.clock.now()
  state.limits = (await $.session.usage()).rateLimits
  const reset = resetAt(state.limits, now)

  const dueAt = (reset ?? now) + GRACE_MS

  // StopFailure と、エラーで終わったターンの両方が同じ停止を知らせることがある
  if (state.pending !== undefined && state.pending.sentAt === undefined && state.pending.dueAt === dueAt) return

  // 送った continue がまた上限に当たったときは、回数を持ち越す
  state.pending = { dueAt, attempts: state.pending?.attempts ?? 0 }
  state.isTurnRunning = false
  state.ticker ??= $.clock.every(TICK_MS, () => void tick($, state))

  await fluid($, ['log', 'claude',
    `Usage limit hit; the hooks module looks again at ${new Date(state.pending.dueAt).toISOString()}`])
}

// 本線のターンが始まった。エージェント自身か人が続けたなら、待つのをやめる
async function turnStarted($: EngineInterface, state: State) {
  state.isTurnRunning = true
  const pending = state.pending
  if (pending === undefined) return

  const now = await $.clock.now()
  const isOwn = pending.sentAt !== undefined && now - pending.sentAt < OWN_TURN_MS
  if (!isOwn) stopWatching(state)
}

async function started($: EngineInterface, state: State) {
  await $.env.set('FLUID_MOD', '1')
  state.limits = (await $.session.usage()).rateLimits
  void observe($, state)
}

export const register: Register = on => {
  const state: State = { limits: [], isTurnRunning: false }

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await started($, state)
    return result
  })

  // 読み取りの受け渡しは待たない: フックには持ち時間がある
  on('session.measure', ($, e, next) => {
    if (e.changed.includes('rateLimits')) {
      state.limits = e.rateLimits
      void observe($, state)
    }
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) await turnStarted($, state)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) {
      state.isTurnRunning = false
      // 送った continue が答えまで進んだ: 再開できた
      if (state.pending?.sentAt !== undefined && e.reason === 'answer') stopWatching(state)
      // エラーで終わり、窓が使い切られている: 上限で止まった
      if (e.reason === 'error' && isLimited((await $.session.usage()).rateLimits)) await stopped($, state)
    }
    return result
  })

  // 見るだけのフック: 失敗しても StopFailure はそのまま進める
  on('classic.StopFailure', async ($, e, next) => {
    const result = await next(e)
    if (e.error === 'rate_limit' && e.agent_id === undefined) await stopped($, state)
    return result
  }).catch(($, e, next) => next(e))

  on('session.end', ($, e, next) => {
    stopWatching(state)
    return next(e)
  })
}
