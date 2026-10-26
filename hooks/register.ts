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
// 起動される /fluid:install はそれを見て、読み取りが届くかどうかを伝える。
// Claude Code の読み取りと再開は、0.3.0 からこのモジュールだけが受け持つ。

import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

// fluid.sh の RESUME_GRACE と同じ: リセットの後、エージェント自身の続行に先を譲る時間
export const GRACE_MS = 180_000
// continue を送ってから、効いたかどうかを見るまでの時間
export const VERIFY_MS = 90_000
// 送っても止まったままなら、この回数であきらめて知らせる
export const MAX_ATTEMPTS = 2
// 待っている間の見回りの間隔。スリープから覚めても次の見回りで追いつく
export const TICK_MS = 30_000
// あきらめたことを知らせられなかったとき、知らせ直すまでの間隔
export const NOTIFY_RETRY_MS = 600_000
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
  // continue を送っている最中。その間に始まるターンは自分のもの
  isSending?: boolean
}

// セッションの間だけ持つ状態。モジュールが読み直されれば初めからになる
type State = {
  limits: readonly SessionRateLimit[]
  pending?: Pending
  isTurnRunning: boolean
  ticker?: { cancel: () => void }
  // 見回りの途中。一回の見回りが次の周期より長引いても、二つ目は走らせない
  isTicking?: boolean
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

// 止めた窓が開く時刻（ミリ秒）。長い窓が埋まっていればそちら、なければ短い窓。
// 長い窓が埋まっていて開く時刻が分からなければ、分からないと答える: 短い窓の
// 時刻に送っても、また止まるだけ
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

// fluid.sh を一度呼ぶ。入っていなければ（/fluid:install の前）何もしない。
// うまくいったかどうかを返す
async function fluid($: EngineInterface, args: string[], stdin?: string): Promise<boolean> {
  const home = await $.env.get('HOME')
  if (home === undefined) return false
  try {
    // at への書き込みの途中で止めると、半端なジョブが残る（0.2.3）。待つのは
    // フックではないので、余裕を持たせる
    const result = await $.process.run([`${home}/.fluid/fluid.sh`, ...args], { cwd: '/', stdin, timeoutMs: 60_000 })
    return result.exitCode === 0
  } catch {
    // 未インストール、または一時的な失敗。次の読み取りがまた届く
    return false
  }
}

// Fluid が入っているか。プラグインだけが入っている、または /fluid:uninstall の
// 後は、セッションに何も送らない
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

// 待っている再開の見回り。重ならないように一つずつ
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

  // あきらめたことは、届くまで知らせ直す（通知の設定がまだ、一時的な失敗）
  if (pending.attempts >= MAX_ATTEMPTS) {
    const isDelivered = await fluid($, ['notify', 'resume-failed',
      `Claude Code did not continue a session after its usage limit reset, and neither did Fluid after ${pending.attempts} tries. It is waiting for you.`])
    if (state.pending !== pending) return
    if (isDelivered) stopWatching(state)
    else pending.dueAt = now + NOTIFY_RETRY_MS
    return
  }

  // 待っている間に /fluid:uninstall されていれば、もう送らない。入力欄を
  // 読む前に確かめる: 読んでから送るまでの間には何も待たない
  if (!(await isInstalled($))) {
    stopWatching(state)
    return
  }
  if (state.pending !== pending || state.isTurnRunning) return

  // 入力欄に書きかけがあれば、誰かがそこにいる。混ぜて送らずに任せる
  const box = await $.prompt.read()
  if (box.text.trim() !== '') {
    stopWatching(state)
    await fluid($, ['log', 'claude', 'Someone is typing in the stopped session; leaving it to them'])
    return
  }

  // 入力欄を読んでいる間に誰か（エージェント自身を含む）が続けていれば送らない
  if (state.pending !== pending || state.isTurnRunning) return

  pending.attempts += 1
  pending.isSending = true
  try {
    await $.prompt.submit({ text: 'continue', asUser: true })
  } finally {
    pending.isSending = false
  }
  // 時刻は送った後で取る。入力欄の読み取りが長引いても、自分のターンを
  // 他人のものと取り違えない
  pending.sentAt = await $.clock.now()
  pending.dueAt = pending.sentAt + VERIFY_MS
  void fluid($, ['log', 'claude', `Sent continue to the stopped session, attempt ${pending.attempts}`])
}

// 上限で止まった: リセットとその後の猶予を待って見回る
async function stopped($: EngineInterface, state: State) {
  // Fluid が入っていなければ、止まったセッションには手を出さない
  if (!(await isInstalled($))) {
    stopWatching(state)
    return
  }

  const now = await $.clock.now()
  state.limits = (await $.session.usage()).rateLimits
  const reset = resetAt(state.limits, now)

  // 開く時刻の分かる使用量の窓（サブスクリプションの 5 時間・週）がなければ、
  // 止めたのは API キーや gateway の 429 など、Fluid の扱う窓ではない。
  // 従量課金で人のいない間に続けることになるので、送らない
  if (reset === undefined) {
    stopWatching(state)
    await fluid($, ['log', 'claude', 'Stopped on a limit with no usage window to wait for; not resuming'])
    return
  }

  const dueAt = reset + GRACE_MS

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

  if (pending.isSending) return
  const now = await $.clock.now()
  const isOwn = pending.sentAt !== undefined && now - pending.sentAt < OWN_TURN_MS
  if (!isOwn) stopWatching(state)
}

// Restart to update: when Claude Code has installed a newer build in the
// background, a session in tmux that nobody is attached to, with no turn
// running, an empty prompt box and nothing done for RESTART_IDLE_MS, has tmux
// replace its process with `claude -r <session id>`, then a shell.
// AUTO_RESTART_TO_UPDATE in the settings' env: `on` restarts, `dry` only logs
// what it would do, anything else (the default) does nothing.

export const RESTART_CHECK_MS = 5 * 60_000
export const RESTART_IDLE_MS = 10 * 60_000
// A restart onto the same version is never tried twice within this window, so
// a claude on PATH other than the running one cannot loop
export const RESTART_RETRY_MS = 6 * 60 * 60_000

type Restart = {
  isTurnRunning: boolean
  lastActivity: number
  isChecking?: boolean
  // Dry mode logs each target version once
  loggedFor?: string
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

// Nobody is there: no client attached to the pane's session, nothing in the
// prompt box, no turn running. Asked again right before the respawn, since a
// person may come back while anything slow runs
async function isUnattended($: EngineInterface, restart: Restart, pane: string): Promise<boolean> {
  if (restart.isTurnRunning) return false
  const attached = await sh($, 'tmux display -p -t "$1" "#{session_attached}"', [pane])
  if (attached !== '0') return false
  if ((await $.prompt.read()).text.trim() !== '') return false
  return !restart.isTurnRunning
}

async function restartCheck($: EngineInterface, restart: Restart) {
  const mode = await $.env.get('AUTO_RESTART_TO_UPDATE')
  if (mode !== 'dry' && mode !== 'on') return
  if (restart.isTurnRunning) return
  const now = await $.clock.now()
  if (now - restart.lastActivity < RESTART_IDLE_MS) return
  if (!(await isInstalled($))) return

  // The process environment, which $.env (the settings files) does not see
  const pane = await sh($, 'printf %s "$TMUX_PANE"')
  if (!pane) return

  const claude = await sh($, 'command -v claude')
  if (!claude) return
  const onDisk = parseVersion((await sh($, '"$1" --version', [claude])) ?? '')
  const running = (await $.session.version()).version
  // Only forward: a claude on PATH older than the running one is not an update
  if (onDisk === undefined || !isNewer(onDisk, running)) return

  const last = (await $.store.get('lastRestart')) as { target?: string; at?: number } | undefined
  if (last?.target === onDisk && last.at !== undefined && now - last.at < RESTART_RETRY_MS) return

  if (!(await isUnattended($, restart, pane))) return

  const id = await $.session.id()
  if (!SESSION_ID.test(id)) return
  const cwd = await $.session.cwd()

  if (mode === 'dry') {
    if (restart.loggedFor !== onDisk) {
      restart.loggedFor = onDisk
      $.ui.log(`restart to update (dry): would restart ${running} -> ${onDisk} at ${stamp(now)} in ${pane} as ${claude} -r ${id}`)
    }
    return
  }

  // Everything that waits comes before the last look, so a turn cannot start
  // between it and the respawn. The record is taken back if it is not made
  await fluid($, ['log', 'claude', `Restarting an idle session in tmux to update, ${running} -> ${onDisk}`])
  await $.store.set('lastRestart', { target: onDisk, at: now, from: running, id })
  if (!(await isUnattended($, restart, pane)) || restart.isTurnRunning) {
    await $.store.delete('lastRestart')
    void fluid($, ['log', 'claude', 'Someone came back to the session; not restarting it'])
    return
  }

  // The time the check began, seconds ago: asking the clock again would wait
  $.ui.log(`restart to update: ${running} -> ${onDisk} at ${stamp(now)}`)
  // tmux 3.0+ runs the trailing arguments as an argv, so nothing is quoted into
  // a command line. The shell after claude keeps the pane usable if it fails
  await sh($, 'tmux respawn-pane -k -t "$1" -c "$2" sh -c \'"$0" -r "$1"; exec "${SHELL:-sh}"\' "$3" "$4"',
    [pane, cwd, claude, id])
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
      restart.ticker?.cancel()
      restart.ticker = $.clock.every(RESTART_CHECK_MS, () => void restartTick($, restart))
    } catch {
      // No ticker: the session runs as if restart to update were off
    }
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
    restart.ticker?.cancel()
    restart.ticker = undefined
    stopWatching(state)
    return next(e)
  })
}
