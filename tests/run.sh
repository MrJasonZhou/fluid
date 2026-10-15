#!/usr/bin/env bash
# Integration tests for Fluid.
#
#   bash tests/run.sh
#
# Everything runs inside a throwaway directory: its own HOME, and fake claude,
# at, atq, atrm, systemctl, pgrep, launchctl and uname on PATH. The real at queue and
# settings.json are never touched. Needs jq, as Fluid does; flock and
# timeout are used where they exist, as on a Mac they do not.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install-fluid.sh"
MARKER="/.fluid/fluid.sh"

export CP_TEST
CP_TEST="$(mktemp -d)"
FAKES="$CP_TEST/bin"
QUEUE="$CP_TEST/queue"
mkdir -p "$FAKES" "$QUEUE"
trap 'rm -rf "$CP_TEST"' EXIT

# The suite runs on the at scheduler wherever it is; the macOS section below
# switches to launchd itself
export FLUID_SCHEDULER=at

# Fluid のフック・モジュールが動いている Claude Code の中からテストを走らせても、
# その印を持ち込まない。必要な所では各テストが自分で立てる
unset FLUID_MOD

PASS=0
FAIL=0

check() {
    if eval "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $1"
    fi
}

section() {
    echo "== $1"
}

# ------------------------------------------------------------------ fakes

# at: -c prints a queued job, -t queues stdin and answers like the real one
cat > "$FAKES/at" <<'EOF'
#!/usr/bin/env bash
# Fluid hands at only a few variables, CP_TEST not among them
CP_TEST="$(cd "$(dirname "$0")/.." && pwd)"
q="$CP_TEST/queue"
if [[ "$1" == -c ]]; then
    cat "$q/$2" 2>/dev/null
    exit
fi
# 本物の at と同じく、提出時の作業ディレクトリと環境をジョブと一緒に記録する
pwd > "$CP_TEST/at-cwd"
env > "$CP_TEST/at-env"
if [[ -e "$CP_TEST/at-refuse" ]]; then
    echo "Can't open /var/run/atd.pid to signal atd. No atd running?" >&2
    exit 1
fi
last="$(ls "$q" | sort -n | tail -1)"
n=$(( ${last:-0} + 1 ))
cat > "$q/$n"
echo "job $n at $2"
EOF

# 本物と同じく最後の列が持ち主。ジョブに "# owner=" の行があればその人のもの
cat > "$FAKES/atq" <<'EOF'
#!/usr/bin/env bash
for f in "$CP_TEST/queue"/*; do
    [[ -e "$f" ]] || continue
    owner="$(sed -n 's/^# owner=//p' "$f")"
    printf '%s\tThu Jan  1 00:00:00 2099 a %s\n' "$(basename "$f")" "${owner:-$(id -un)}"
done
EOF

cat > "$FAKES/atrm" <<'EOF'
#!/usr/bin/env bash
[[ -e "$CP_TEST/at-refuse" ]] && exit 1
rm -f "$CP_TEST/queue/$1"
EOF

# claude: behaviour picked by a file, so a test can change it between runs
cat > "$FAKES/claude" <<'EOF'
#!/usr/bin/env bash
echo run >> "$CP_TEST/claude-runs"
echo "$*" >> "$CP_TEST/claude-args"
case "$(cat "$CP_TEST/claude-mode" 2>/dev/null)" in
    auth) echo "OAuth refresh token is no longer valid; run /login to re-authenticate" >&2; exit 1 ;;
    # A refresh that failed this once, and one that lost the refresh lock:
    # Claude Code's own wording for both
    transient) echo "Failed to authenticate: OAuth session expired and could not be refreshed" >&2; exit 1 ;;
    lockheld)  echo "OAuth access token could not be refreshed: another Claude Code process is holding the refresh lock" >&2; exit 1 ;;
    fail) echo "API Error: Overloaded" >&2; exit 1 ;;
    # 応答に時間のかかる warmup
    slow) sleep 2; echo OK ;;
    # An agent that has dropped the model it is asked for
    badmodel)
        if [[ "$*" == *--model* ]]; then
            echo '[claude-code:unrecognized_model] not described by this version' >&2
            exit 1
        fi
        echo OK ;;
    *)    echo OK ;;
esac
EOF

# codex: records its invocation, so a test can check the provider's own command
cat > "$FAKES/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "exec --help" ]]; then
    [[ -e "$CP_TEST/codex-old" ]] || echo "      --ephemeral"
    exit 0
fi
echo "$*" >> "$CP_TEST/codex-runs"
pwd > "$CP_TEST/codex-cwd"
case "$(cat "$CP_TEST/codex-mode" 2>/dev/null)" in
    # 終了後もバックグラウンドに子プロセスを残すエージェント
    child) sleep 5 </dev/null >/dev/null 2>&1 & ;;
esac
echo codex-ok
EOF

# agy: another agent with a status line hook of its own
cat > "$FAKES/agy" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CP_TEST/agy-runs"
echo agy-ok
EOF

# The user's own status line
cat > "$FAKES/cs" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf CS
EOF

# Another program that wraps whatever status line it finds
cat > "$FAKES/xwrap" <<'EOF'
#!/usr/bin/env bash
s="$HOME/.gemini/antigravity-cli/settings.json"
d="$HOME/.xwrap-downstream"
case "$1" in
    install)
        jq -r .statusLine.command "$s" > "$d"
        jq --arg c "$CP_TEST/bin/xwrap render" '.statusLine.command = $c' "$s" > "$s.t" && mv "$s.t" "$s"
        ;;
    uninstall)
        jq --arg c "$(cat "$d")" '.statusLine.command = $c' "$s" > "$s.t" && mv "$s.t" "$s"
        rm -f "$d"
        ;;
    render)
        printf 'X['
        bash -c "$(cat "$d")"
        printf ']'
        ;;
esac
EOF

# Another program that replaces the status line and calls nothing
cat > "$FAKES/yreplace" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf Y
EOF

# Same, but it holds the chain probe in place until the test lets go
# ($CP_TEST/probe-release) or 8 seconds pass, so a race with it is not left to timing
cat > "$FAKES/slowreplace" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
for _ in $(seq 1 80); do
    [[ -e "$CP_TEST/probe-release" ]] && break
    sleep 0.1
done
printf Y
EOF

# 自分のプロセスグループに子を残す状態栏
cat > "$FAKES/spawner" <<'EOF'
#!/usr/bin/env bash
sleep 30 </dev/null >/dev/null 2>&1 &
echo $! > "$CP_TEST/spawned"
cat >/dev/null
printf Y
EOF

# mv: 設定ファイルへの mv を、$CP_TEST/mv-allow に書いた回数だけ通し、それ以降は失敗する
cat > "$FAKES/mv" <<'EOF'
#!/usr/bin/env bash
if [[ -e "$CP_TEST/mv-allow" && "${@: -1}" == *settings.json ]]; then
    n="$(cat "$CP_TEST/mv-allow")"
    (( n > 0 )) || exit 1
    echo $((n - 1)) > "$CP_TEST/mv-allow"
fi
for real in /bin/mv /usr/bin/mv; do
    [[ -x "$real" ]] && exec "$real" "$@"
done
exit 127
EOF

# systemctl and pgrep report atd up or down, as the test switches it
cat > "$FAKES/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "is-active --quiet atd" ]] || exit 1
[[ "$(cat "$CP_TEST/atd" 2>/dev/null)" == up ]]
EOF

cat > "$FAKES/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-x atd" ]] || exit 1
[[ "$(cat "$CP_TEST/atd" 2>/dev/null)" == up ]]
EOF

# launchctl: logs what it is asked, and loads unless told to refuse
cat > "$FAKES/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CP_TEST/launchctl-log"
case "$1" in
    bootstrap|load) [[ ! -e "$CP_TEST/launchctl-refuse" ]] ;;
    *) exit 0 ;;
esac
EOF

# uname: the kernel name a test picks, the real answer otherwise
cat > "$FAKES/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == -s && -s "$CP_TEST/uname" ]]; then cat "$CP_TEST/uname"; exit; fi
exec /usr/bin/uname "$@"
EOF

chmod +x "$FAKES"/*

# claude だけが PATH にない環境: 偽のコマンドから claude を除き、jq を足す
NOCLAUDE="$CP_TEST/noclaude"
mkdir -p "$NOCLAUDE"
for _f in "$FAKES"/*; do
    [[ "$(basename "$_f")" == claude ]] || ln -s "$_f" "$NOCLAUDE/"
done
ln -s "$(command -v jq)" "$NOCLAUDE/jq"
NOCLAUDE_PATH="$NOCLAUDE:/usr/bin:/bin:/usr/sbin:/sbin"

# ---------------------------------------------------------------- helpers

new_home() {
    H="$CP_TEST/home-$1"
    rm -rf "$H"
    mkdir -p "$H/.claude" "$H/.gemini/antigravity-cli"
    # The status line under test is agy's: Claude Code's is never wrapped
    # since 0.3.0, and CS is only there to show it is left alone
    S="$H/.gemini/antigravity-cli/settings.json"
    CS="$H/.claude/settings.json"
    BASE="$H/.fluid"
    CP="$BASE/fluid.sh"
    ORIGFILE="$BASE/state/agy/original-statusline-command"
    rm -f "$QUEUE"/* "$CP_TEST"/claude-mode "$CP_TEST"/codex-mode "$CP_TEST"/mv-allow "$CP_TEST"/claude-runs "$CP_TEST"/claude-args "$CP_TEST"/codex-runs "$CP_TEST"/agy-runs "$CP_TEST"/notify-*
    AGYS="$H/.gemini/antigravity-cli/settings.json"
    echo up > "$CP_TEST/atd"
}

# GNU date and timeout on Linux, their BSD and perl stand-ins on macOS
tdate() {
    date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2"
}
tmo() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$@"
    else
        perl -e 'alarm shift; exec @ARGV or exit 127' "$@"
    fi
}

# Poll a condition for up to three seconds, for work done in the background
wait_until() {
    local i
    for i in $(seq 1 60); do
        eval "$1" && return 0
        sleep 0.05
    done
    return 1
}

in_home() {
    HOME="$H" PATH="$FAKES:$PATH" "$@"
}

# Write a codex session log carrying limits, the way codex does
codex_log() {
    mkdir -p "$H/.codex/sessions/2026/09/25"
    printf '{"type":"event_msg","payload":{"type":"other"}}\n{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":13,"window_minutes":10080,"resets_at":%s}}}}\n' \
        "$1" "$2" > "$H/.codex/sessions/2026/09/25/rollout-2026-09-25T01-00-00-test.jsonl"
}

install_cp() {
    in_home bash "$INSTALLER" "$@"
}

cp_run() {
    in_home "$CP" "$@"
}

render() {
    printf '{"model":{"display_name":"x"},"workspace":{"current_dir":"/tmp"}}' |
        in_home tmo 5 bash -c "$(jq -r .statusLine.command "$S")"
}

our_jobs() {
    echo $(( $(grep -lF "$MARKER" "$QUEUE"/* 2>/dev/null | wc -l) ))
}

make_notifier() {
    mkdir -p "$BASE"
    cat > "$BASE/notify.sh" <<'EOF'
#!/usr/bin/env bash
echo "$CP_EVENT" >> "$CP_TEST/notify-attempts"
n="$(cat "$CP_TEST/notify-fail" 2>/dev/null || echo 0)"
if (( n > 0 )); then
    echo $((n - 1)) > "$CP_TEST/notify-fail"
    exit 1
fi
echo "$CP_EVENT" >> "$CP_TEST/notify-delivered"
EOF
    chmod +x "$BASE/notify.sh"
}

# How many lines of $2 are exactly $1; 0 when the file does not exist yet
count() {
    local n
    n="$(grep -cx "$1" "$CP_TEST/$2" 2>/dev/null)" || true
    echo "${n:-0}"
}

with_cs() {
    printf '{"statusLine":{"type":"command","command":"%s","refreshInterval":1}}\n' "$FAKES/cs" > "$S"
}

# ======================================================================
section "install and uninstall keep everything that is not ours"

new_home basic
cat > "$S" <<EOF
{"model":"opus",
 "statusLine":{"type":"command","command":"$FAKES/cs","refreshInterval":1},
 "hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"rtk hook claude"}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"/opt/audit"}]}]}}
EOF
install_cp >/dev/null
check "wraps the status line"      '[[ $(jq -r .statusLine.command "$S") == "$CP statusline agy" ]]'
check "saves the original"         '[[ $(cat "$ORIGFILE") == "$FAKES/cs" ]]'
check "keeps statusLine siblings"  '[[ $(jq .statusLine.refreshInterval "$S") == 1 ]]'
check "adds the status line and nothing else" '[[ $(( $(grep -o "$MARKER" "$S" | wc -l) )) == 1 && $(jq -c ".hooks | keys" "$S") == "[\"PreToolUse\",\"UserPromptSubmit\"]" ]]'
check "renders through wrapper"    '[[ $(render) == CS ]]'

jq '.env = {"FOO":"1"} | .hooks.SessionEnd += [{"hooks":[{"type":"command","command":"/opt/save"}]}]' "$S" > "$S.t" && mv "$S.t" "$S"
# Hooks of ours in any event, beside the user's own, all go on upgrade
jq --arg cp "$CP" '
    .hooks.StopFailure += [{"matcher":"rate_limit","hooks":[{"type":"command","command":($cp + " rate-limit")}]}]
    | .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":($cp + " prompt-submit")}]}]
    | .hooks.SessionEnd += [{"hooks":[{"type":"command","command":($cp + " session-end")}]}]
' "$S" > "$S.t" && mv "$S.t" "$S"
echo "2026-01-01 00:00:00 an earlier line" > "$BASE/fluid.log"
make_notifier
{ echo "$CP scheduled"; head -c 1048576 /dev/zero | tr '\0' x; } > "$QUEUE/1"
echo "/usr/local/bin/nightly" > "$QUEUE/2"

install_cp >/dev/null
check "upgrade: original not doubled"  '[[ $(cat "$ORIGFILE") == "$FAKES/cs" ]]'
check "upgrade: later edits survive"   '[[ $(jq -r .env.FOO "$S") == 1 ]]'
check "upgrade: stray hooks of ours gone"  '[[ $(( $(grep -o "$MARKER" "$S" | wc -l) )) == 1 && $(jq -c ".hooks | keys" "$S") == "[\"PreToolUse\",\"SessionEnd\",\"UserPromptSubmit\"]" ]]'
check "upgrade: user hooks in those events kept" '[[ $(jq -r ".hooks.UserPromptSubmit[0].hooks[0].command, .hooks.SessionEnd[0].hooks[0].command" "$S" | tr "\n" " ") == "/opt/audit /opt/save " ]]'
check "upgrade: log kept"              'grep -q "an earlier line" "$BASE/fluid.log"'
check "upgrade: notifier survives"     '[[ -x "$BASE/notify.sh" ]]'
check "upgrade: big job of ours gone"  '[[ ! -e "$QUEUE/1" ]]'
check "upgrade: foreign job kept"      '[[ -e "$QUEUE/2" ]]'

out="$(install_cp uninstall)"
check "uninstall: says so"             '[[ $out == *"uninstalled"* ]]'
check "uninstall: original restored"   '[[ $(jq -c .statusLine "$S") == "{\"type\":\"command\",\"command\":\"$FAKES/cs\",\"refreshInterval\":1}" ]]'
check "uninstall: no trace of ours"    '! grep -qF "$MARKER" "$S"'
check "uninstall: other hooks intact"  '[[ $(jq -c "[.hooks[][] .hooks[] .command] | sort" "$S") == "[\"/opt/audit\",\"/opt/save\",\"rtk hook claude\"]" ]]'
check "uninstall: later edits survive" '[[ $(jq -r .env.FOO "$S") == 1 && $(jq -r .model "$S") == opus ]]'
check "uninstall: directory gone"      '[[ ! -e "$BASE" ]]'
check "uninstall: no jobs of ours"     '[[ $(our_jobs) == 0 && -e "$QUEUE/2" ]]'
check "uninstall: backup made"         'compgen -G "$S.fluid-uninstall-backup.*" >/dev/null'

before="$(cksum < "$S")"
out="$(install_cp uninstall)"
rc=$?
check "uninstall again: exit 0"          '[[ $rc == 0 ]]'
check "uninstall again: not installed"   '[[ $out == *"not installed"* ]]'
check "uninstall again: file untouched"  '[[ $(cksum < "$S") == "$before" ]]'

new_home nosettings
install_cp uninstall >/dev/null
check "no settings.json: none created"   '[[ ! -e "$S" ]]'

new_home badjson
echo '{broken' > "$S"
before="$(cksum < "$S")"
install_cp uninstall >/dev/null 2>&1
rc=$?
check "invalid JSON: refused"            '[[ $rc == 1 && $(cksum < "$S") == "$before" ]]'

install_cp --help >/dev/null 2>&1; rc=$?
check "--help exits 0"                   '[[ $rc == 0 ]]'
install_cp bogus >/dev/null 2>&1; rc=$?
check "unknown action exits 2"           '[[ $rc == 2 ]]'

# ======================================================================
section "strip filter edge cases"

STRIP_FILTER="$(sed -n "/^STRIP_FILTER='$/,/^'$/p" "$INSTALLER" | sed '1d;$d')"
eval "$(grep "^OURS_RE=" "$INSTALLER")"
strip() {
    jq -cS --arg re "$OURS_RE" --arg orig "${2:-}" "$STRIP_FILTER" <<< "$1"
}
norm() {
    jq -cS . <<< "$1"
}
W="/h/.fluid/fluid.sh"

check "never restores our own wrapper" \
    '[[ $(strip "{\"statusLine\":{\"command\":\"$W statusline\"}}" "$W statusline") == "{}" ]]'
check "shared group keeps the foreign hook" \
    '[[ $(strip "{\"hooks\":{\"E\":[{\"hooks\":[{\"command\":\"/opt/a\"},{\"command\":\"$W x\"}]}]}}") == "$(norm "{\"hooks\":{\"E\":[{\"hooks\":[{\"command\":\"/opt/a\"}]}]}}")" ]]'
check "pre-existing empty group kept" \
    '[[ $(strip "{\"hooks\":{\"E\":[{\"hooks\":[]}]}}") == "$(norm "{\"hooks\":{\"E\":[{\"hooks\":[]}]}}")" ]]'
check "user empty hooks object kept" \
    '[[ $(strip "{\"hooks\":{}}") == "{\"hooks\":{}}" ]]'
# 我々のコマンドに手を加えたもの、我々のスクリプトを呼ぶ別のコマンドは利用者のもの
for theirs in "$W statusline agy; echo done" "/opt/audit && $W rate-limit claude" "$W statusline agy | tee /tmp/x"; do
    check "a command of the user's that calls ours stays: $theirs" \
        '[[ $(strip "{\"statusLine\":{\"command\":\"$theirs\"},\"hooks\":{\"E\":[{\"hooks\":[{\"command\":\"$theirs\"}]}]}}" /x) == "$(norm "{\"statusLine\":{\"command\":\"$theirs\"},\"hooks\":{\"E\":[{\"hooks\":[{\"command\":\"$theirs\"}]}]}}")" ]]'
done
check "a path quoted for the shell is still ours" \
    '[[ $(strip "{\"statusLine\":{\"command\":\"/h/a\\\\ b/.fluid/fluid.sh statusline agy\"}}") == "{}" ]]'
for odd in '{"statusLine":"text"}' '{"hooks":[]}' '{"hooks":{"X":"s"}}' '{"hooks":{"X":[1,null]}}' '{"hooks":{"X":[{"hooks":"n"}]}}'; do
    check "odd shape passes through: $odd" '[[ $(strip "$odd") == "$(norm "$odd")" ]]'
done

# HOME に空白があっても、包んだ状態栏は動き、きれいに外れる
new_home "with space"
with_cs
install_cp >/dev/null
check "a home with a space: the wrapper runs"   '[[ $(render) == CS ]]'
install_cp uninstall >/dev/null
check "and comes out again"                     '[[ $(jq -r .statusLine.command "$S") == "$FAKES/cs" && ! -e "$BASE" ]]'

# ======================================================================
section "another program wraps the status line around ours"

new_home chain
with_cs
install_cp >/dev/null
in_home "$FAKES/xwrap" install
check "chain renders"                  '[[ $(render) == "X[CS]" ]]'

out="$(install_cp)"
check "upgrade: wrapper left alone"    '[[ $(jq -r .statusLine.command "$S") == "$FAKES/xwrap render" ]]'
check "upgrade: still renders cs"      '[[ $(cat "$ORIGFILE") == "$FAKES/cs" ]]'
check "upgrade: full script"           'grep -q "^observe()" "$CP"'
check "upgrade: renders, no loop"      '[[ $(render) == "X[CS]" ]]'

out="$(install_cp uninstall)"
check "uninstall: leaves pass-through" '[[ $out == *pass-through* ]] && grep -q "was uninstalled" "$CP"'
check "uninstall: chain still renders" '[[ $(render) == "X[CS]" ]]'
check "uninstall: runtime state gone"  '[[ ! -e "$BASE/state/claude/at_target" ]] && [[ -s "$ORIGFILE" ]]'
before="$(cksum < "$S")"
install_cp uninstall >/dev/null
check "uninstall again: still renders" '[[ $(render) == "X[CS]" && $(cksum < "$S") == "$before" ]]'
in_home "$FAKES/xwrap" uninstall
install_cp uninstall >/dev/null
check "wrapper gone: original back"    '[[ $(jq -r .statusLine.command "$S") == "$FAKES/cs" && ! -e "$BASE" ]]'

new_home replaced
with_cs
install_cp >/dev/null
jq --arg c "$FAKES/yreplace" '.statusLine.command = $c' "$S" > "$S.t" && mv "$S.t" "$S"
out="$(install_cp uninstall)"
check "replaced, not wrapped: no stub" '[[ $out != *pass-through* && ! -e "$BASE" ]]'

new_home loop
with_cs
install_cp >/dev/null
in_home "$FAKES/xwrap" install
printf '%s\n' "$FAKES/xwrap render" > "$BASE/original-statusline-command"
jq --arg c "$CP statusline" '.statusLine.command = $c' "$S" > "$S.t" && mv "$S.t" "$S"
render >/dev/null
rc=$?
check "hand-made loop terminates"      '[[ $rc == 0 ]]'

# ======================================================================
section "the chain probe swallows nothing and never outlives the installer"

use_slow_replacement() {
    new_home "$1"
    with_cs
    install_cp >/dev/null
    jq --arg c "$FAKES/slowreplace" '.statusLine.command = $c' "$S" > "$S.t" && mv "$S.t" "$S"
    rm -f "$CP_TEST/claude-runs" "$CP_TEST/probe-release"
}

# Up to ten seconds: on a busy machine the installer takes a while to get
# there, and a SIGINT sent before then lands while bash waits on a child, which
# bash then ignores
wait_for_probe() {
    local i
    for i in $(seq 1 200); do
        # The real script has been swapped out (true of old and new probes)
        [[ -f "$CP" ]] && ! grep -q "^observe()" "$CP" && return 0
        sleep 0.05
    done
    return 1
}

use_slow_replacement probe-race
install_cp uninstall > "$CP_TEST/probe.out" 2>&1 &
installer=$!
wait_for_probe
check "probe is in place for the race"          '[[ $? == 0 ]]'
cp_run scheduled claude >/dev/null
cp_run status >/dev/null
touch "$CP_TEST/probe-release"
wait "$installer"
check "scheduled run during probe still ran"    '[[ -s "$CP_TEST/claude-runs" ]]'
check "other calls during probe are not a hit"   '[[ $(cat "$CP_TEST/probe.out") != *pass-through* && ! -e "$BASE" ]]'

# A suite started in the background inherits SIGINT ignored, which no shell
# below it can undo; INT is then not something the installer can ever get
SIGS="HUP TERM INT"
[[ -n "$(trap -p INT)" ]] && SIGS="HUP TERM"
for sig in $SIGS; do
    use_slow_replacement "probe-$sig"
    # Job control gives the background installer its own process group and
    # keeps SIGINT from being ignored, as it would be from a terminal
    set -m
    HOME="$H" PATH="$FAKES:$PATH" bash "$INSTALLER" uninstall >/dev/null 2>&1 &
    installer=$!
    set +m
    wait_for_probe
    kill -"$sig" "$installer"
    wait "$installer"
    rc=$?
    touch "$CP_TEST/probe-release"
    check "SIG$sig during probe: installer stops"          '[[ $rc != 0 ]]'
    check "SIG$sig during probe: real script restored"     'grep -q "^observe()" "$CP"'
    check "SIG$sig during probe: no temporary files left"  '! compgen -G "$BASE/.saved.*" >/dev/null && ! compgen -G "$BASE/.probe.*" >/dev/null'
    check "SIG$sig during probe: still installed"          '[[ -d "$BASE/state" ]]'
done

# ======================================================================
section "the probe tells one agent's status line from another's"

# 調べるために起こした状態栏が、子プロセスを後に残さない
new_home probe-children
with_cs
install_cp >/dev/null
jq --arg c "$FAKES/spawner" '.statusLine.command = $c' "$S" > "$S.t" && mv "$S.t" "$S"
rm -f "$CP_TEST/spawned"
install_cp uninstall >/dev/null 2>&1
check "the probe ran it"                  '[[ -s "$CP_TEST/spawned" ]]'
# 止めた子が回収されずにゾンビで残る環境（PID 1 が回収しないコンテナ）もある
check "and nothing it started outlives it" '[[ $(ps -o stat= -p "$(cat "$CP_TEST/spawned")" 2>/dev/null) != [!Z]* ]]'

# ======================================================================
section "uninstall cleans up what it can, and waits for what is running"

# claude が PATH から見えなくなっても、設定に残した痕跡は消える
new_home gone-claude
with_cs
install_cp >/dev/null
HOME="$H" PATH="$NOCLAUDE_PATH" bash "$INSTALLER" uninstall >/dev/null 2>&1
check "status line and hook taken out without claude on PATH" '! grep -qF "$MARKER" "$S" && [[ $(jq -r .statusLine.command "$S") == "$FAKES/cs" ]]'
check "and the rest removed"                                  '[[ ! -e "$BASE" && $(our_jobs) == 0 ]]'

# 走っている warmup が終わるのを待ってから消す
new_home inflight
with_cs
install_cp >/dev/null
echo slow > "$CP_TEST/claude-mode"
cp_run scheduled claude >/dev/null 2>&1 &
runner=$!
wait_until '[[ -s "$CP_TEST/claude-runs" ]]'
out="$(install_cp uninstall)"
wait "$runner"
check "it says it is waiting"                     '[[ $out == *"Waiting for a run in progress"* ]]'
check "the finished warmup leaves nothing behind" '[[ ! -e "$BASE" && $(our_jobs) == 0 ]]'

# 状態栏の更新が卸す最中にも読み取りを渡してくる。消している最中のディレクトリに
# 書き込まれても卸しは失敗せず、終わった後に ~/.fluid が作り直されることもない
new_home busy
with_cs
install_cp >/dev/null
reading="$(printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$(( $(date +%s) + 3600 ))")"
(
    for _ in $(seq 1 400); do
        printf '%s' "$reading" | in_home "$CP" observe claude mod >/dev/null 2>&1
    done
) &
feeder=$!
wait_until '[[ -s "$BASE/state/claude/last_reading" ]]'
install_cp uninstall >/dev/null 2>&1; rc=$?
kill "$feeder" 2>/dev/null
wait "$feeder" 2>/dev/null
check "readings during uninstall: it still succeeds" '[[ $rc == 0 ]]'
check "and nothing is built back up afterwards"     '[[ ! -e "$BASE" ]] && ! compgen -G "$BASE.removing.*" >/dev/null'
check "and no job is left for the script it removed" '[[ $(our_jobs) == 0 ]]'

# 他のユーザーのジョブには触れない（root の atq には全員のジョブが並ぶ）
new_home others
with_cs
install_cp >/dev/null
printf '# owner=someoneelse\n/home/someoneelse/.fluid/fluid.sh scheduled claude\n' > "$QUEUE/7"
install_cp uninstall >/dev/null
check "another user's job is left alone" '[[ -e "$QUEUE/7" ]]'

# ======================================================================
section "settings are edited where they live, and backups do not pile up"

new_home links
mkdir -p "$H/dotfiles"
printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$FAKES/cs" > "$H/dotfiles/agy.json"
chmod 644 "$H/dotfiles/agy.json"
ln -sf ../../dotfiles/agy.json "$S"
for i in 1 2 3 4 5 6 7; do
    echo '{}' > "$S.fluid-install-backup.20200101-00000$i"
done
install_cp >/dev/null
check "a linked settings file stays a link"   '[[ -L $S && $(jq -r .statusLine.command "$H/dotfiles/agy.json") == "$CP statusline agy" ]]'
check "and keeps its permissions"             '[[ $(ls -lL "$S" | cut -c1-10) == "-rw-r--r--" ]]'
check "only the five newest backups are kept" '[[ $(( $(compgen -G "$S.fluid-*-backup.*" | wc -l) )) == 5 && ! -e "$S.fluid-install-backup.20200101-000003" && -e "$S.fluid-install-backup.20200101-000007" ]]'
install_cp uninstall >/dev/null
check "uninstall edits through the link too"  '[[ -L $S ]] && ! grep -qF "$MARKER" "$H/dotfiles/agy.json"'

# ======================================================================
section "an install that stops half way leaves the schedule in place"

new_home halfway
with_cs
install_cp >/dev/null
T="$(( $(date +%s) + 3600 ))"
printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$T" | cp_run observe claude >/dev/null
check "a run is planned"            '[[ $(our_jobs) == 1 ]]'
# 古い設定を取り除く書き換えは通り、包み直す書き換えで失敗する
echo 1 > "$CP_TEST/mv-allow"
out="$(install_cp 2>&1)"; rc=$?
rm -f "$CP_TEST/mv-allow"
check "the installer fails and says so"  '[[ $rc != 0 && $out == *"did not finish"* ]]'
check "the user's status line is intact" '[[ $(jq -r .statusLine.command "$S") == "$FAKES/cs" ]]'
check "and the planned run is back"      '[[ $(our_jobs) == 1 && $(cat "$BASE/state/claude/at_target") == $(( T + 15 )) ]]'
install_cp uninstall >/dev/null

# ======================================================================
section "upgrade keeps runtime state; uninstall removes it"

new_home state
with_cs
install_cp >/dev/null
mkdir -p "$BASE/state/claude"
now="$(date +%s)"
target=$((now + 3600))
echo $((now + 3585))            > "$BASE/state/claude/five_hour_reset"
echo 42                          > "$BASE/state/claude/five_hour_pct"
echo $((now + 86400))           > "$BASE/state/claude/seven_day_reset"
echo 10                          > "$BASE/state/claude/seven_day_pct"
echo 2                           > "$BASE/state/claude/failure_count"
echo "$now"                      > "$BASE/state/claude/last_success"
: > "$BASE/state/claude/notified-failing"
echo "$target"                   > "$BASE/state/claude/at_target"
echo pending-rate-limit          > "$BASE/state/claude/at_reason"
echo "$CP scheduled"             > "$QUEUE/7"
echo 7                           > "$BASE/state/claude/at_job"
make_notifier

install_cp >/dev/null
check "reset times kept"           '[[ $(cat "$BASE/state/claude/five_hour_reset") == $((now + 3585)) && $(cat "$BASE/state/claude/seven_day_pct") == 10 ]]'
check "failure state kept"         '[[ $(cat "$BASE/state/claude/failure_count") == 2 && -e "$BASE/state/claude/notified-failing" ]]'
check "last success kept"          '[[ $(cat "$BASE/state/claude/last_success") == "$now" ]]'
check "notifier kept"              '[[ -x "$BASE/notify.sh" ]]'
check "old job replaced"           '[[ ! -e "$QUEUE/7" && $(our_jobs) == 1 ]]'
check "same target re-armed"       '[[ $(cat "$BASE/state/claude/at_target") == "$target" ]]'
check "same reason kept"           '[[ $(cat "$BASE/state/claude/at_reason") == pending-rate-limit ]]'

# 0.2.x の tmux 再開が残した記録は、アップグレードで片付ける
mkdir -p "$BASE/state/claude/pending" "$BASE/state/claude/resume.lock.d"
echo '{"session":"old"}' > "$BASE/state/claude/pending/old.json"
echo 9 > "$BASE/state/claude/resume_job"
echo "$target" > "$BASE/state/claude/resume_target"
: > "$BASE/state/claude/resume-job.lock"
install_cp >/dev/null
check "old resume records cleared" '[[ ! -e "$BASE/state/claude/pending" && ! -e "$BASE/state/claude/resume_job" && ! -e "$BASE/state/claude/resume_target" && ! -e "$BASE/state/claude/resume.lock.d" && ! -e "$BASE/state/claude/resume-job.lock" ]]'
check "and nothing else of the state" '[[ $(cat "$BASE/state/claude/at_target") == "$target" && $(cat "$BASE/state/claude/failure_count") == 2 ]]'

echo $((now - 600)) > "$BASE/state/claude/at_target"
install_cp >/dev/null
t="$(cat "$BASE/state/claude/at_target")"
check "missed target runs now"     '(( t >= now && t <= $(date +%s) + 30 )) && [[ $(our_jobs) == 1 ]]'

new_home fresh
with_cs
install_cp >/dev/null
check "fresh install: no job yet"  '[[ $(our_jobs) == 0 ]]'

install_cp uninstall >/dev/null
check "uninstall: state removed"   '[[ ! -e "$BASE" && $(our_jobs) == 0 ]]'

gen="$(sed -n '/^cat > "$STAGE\/fluid.sh" <<.FLUID_SCRIPT.$/,/^FLUID_SCRIPT$/p' "$INSTALLER")"
check "generated script never turns errexit on" \
    '(( $(wc -l <<< "$gen") > 500 )) && ! grep -qE "^\s*set -e" <<< "$gen"'

# ======================================================================
section "alerts are marked sent only once delivered"

new_home alert
echo '{}' > "$S"
install_cp >/dev/null
echo auth > "$CP_TEST/claude-mode"

cp_run warmup claude >/dev/null
check "no notifier: nothing marked"      '[[ ! -e "$BASE/state/claude/notified-auth" ]]'

make_notifier
echo 1 > "$CP_TEST/notify-fail"
cp_run warmup claude >/dev/null
check "failed send: attempted"           '[[ $(count auth-required notify-attempts) == 1 ]]'
check "failed send: not marked"          '[[ ! -e "$BASE/state/claude/notified-auth" ]]'

cp_run warmup claude >/dev/null
check "retry: delivered"                 '[[ $(count auth-required notify-delivered) == 1 ]]'
check "retry: now marked"                '[[ -e "$BASE/state/claude/notified-auth" ]]'

cp_run warmup claude >/dev/null
check "marked: not sent again"           '[[ $(count auth-required notify-attempts) == 2 ]]'

echo ok > "$CP_TEST/claude-mode"
echo 1 > "$CP_TEST/notify-fail"
cp_run warmup claude >/dev/null
check "recovery send failed: flag kept"  '[[ -e "$BASE/state/claude/notified-auth" && $(count recovered notify-delivered) == 0 ]]'

cp_run warmup claude >/dev/null
check "recovery retried and delivered"   '[[ $(count recovered notify-delivered) == 1 && ! -e "$BASE/state/claude/notified-auth" ]]'

cp_run warmup claude >/dev/null
check "recovery announced once"          '[[ $(count recovered notify-attempts) == 2 ]]'

echo fail > "$CP_TEST/claude-mode"
for _ in 1 2; do cp_run warmup claude >/dev/null; done
check "two failures: quiet"              '[[ $(count warmup-failing notify-attempts) == 0 ]]'
cp_run warmup claude >/dev/null
check "third failure: announced"         '[[ $(count warmup-failing notify-delivered) == 1 && -e "$BASE/state/claude/notified-failing" ]]'

# ======================================================================
section "a refresh that fixes itself is never an alert"

new_home authwait
echo '{}' > "$S"
install_cp >/dev/null
make_notifier

echo transient > "$CP_TEST/claude-mode"
cp_run warmup claude >/dev/null
check "a one-off refresh failure is not a dead session" '[[ ! -e "$BASE/state/claude/auth_required" && $(cat "$BASE/state/claude/failure_count") == 1 ]]'

echo lockheld > "$CP_TEST/claude-mode"
cp_run warmup claude >/dev/null
check "losing the refresh lock is not either"           '[[ ! -e "$BASE/state/claude/auth_required" ]]'
check "neither of them wakes anyone"                    '[[ $(count auth-required notify-attempts) == 0 ]]'

echo auth > "$CP_TEST/claude-mode"
cp_run warmup claude >/dev/null
check "a dead session: noticed and rechecked"           '[[ -e "$BASE/state/claude/auth_required" && $(cat "$BASE/state/claude/at_reason") == auth-recheck ]]'
check "but still quiet the first time"                  '[[ $(count auth-required notify-attempts) == 0 ]]'

cp_run warmup claude >/dev/null
check "announced once the recheck fails too"            '[[ $(count auth-required notify-delivered) == 1 ]]'
check "and the first failure time is kept"              '[[ $(cat "$BASE/state/claude/auth_required") -le $(date +%s) ]]'

echo ok > "$CP_TEST/claude-mode"
cp_run warmup claude >/dev/null
check "signing in again clears it and says so"          '[[ ! -e "$BASE/state/claude/auth_required" && $(count recovered notify-delivered) == 1 ]]'

install_cp uninstall >/dev/null

# ======================================================================
section "a scheduler that is not running gets noticed"

new_home sched
with_cs
echo down > "$CP_TEST/atd"
out="$(install_cp 2>&1)"
check "install warns when atd is down"      '[[ $out == *"atd is not running"* ]]'
check "status says atd is down"             '[[ $(cp_run status) == *"ATD NOT RUNNING"* ]]'
echo up > "$CP_TEST/atd"
out="$(install_cp 2>&1)"
check "no warning when atd is up"           '[[ $out != *"atd is not running"* ]]'
check "status says atd is running"          '[[ $(cp_run status) == *"Scheduler       : atd running"* ]]'
check "status: no run yet"                  '[[ $(cp_run status) != *"Last run"* ]]'

make_notifier
refresh() {
    printf '{}' | cp_run observe claude >/dev/null
}

mkdir -p "$BASE/state/claude"
echo $(( $(date +%s) + 600 )) > "$BASE/state/claude/at_target"
refresh
sleep 0.5
check "target in the future: not looked at"  '[[ ! -e "$BASE/state/claude/stall_checked_at" ]]'

echo $(( $(date +%s) - 400 )) > "$BASE/state/claude/at_target"
echo 99 > "$BASE/state/claude/at_job"
refresh
wait_until '[[ -e "$BASE/state/claude/stall_checked_at" ]]'
sleep 0.3
check "overdue but no longer queued: quiet" '[[ $(count scheduler-stalled notify-attempts) == 0 ]]'

echo "$CP scheduled" > "$QUEUE/5"
echo 5 > "$BASE/state/claude/at_job"
rm -f "$BASE/state/claude/stall_checked_at"
echo 1 > "$CP_TEST/notify-fail"
refresh
wait_until '[[ $(count scheduler-stalled notify-attempts) == 1 ]]'
check "overdue and queued: alert attempted" '[[ $(count scheduler-stalled notify-attempts) == 1 ]]'
check "failed send: not marked"             '[[ ! -e "$BASE/state/claude/notified-stalled" ]]'
check "status flags the overdue run"        '[[ $(cp_run status) == *OVERDUE* ]]'

refresh
sleep 0.5
check "throttled: no second look straight away" '[[ $(count scheduler-stalled notify-attempts) == 1 ]]'

echo 0 > "$BASE/state/claude/stall_checked_at"
refresh
wait_until '[[ $(count scheduler-stalled notify-delivered) == 1 && -e "$BASE/state/claude/notified-stalled" ]]'
check "retry after grace: delivered, marked" '[[ $(count scheduler-stalled notify-delivered) == 1 && -e "$BASE/state/claude/notified-stalled" ]]'

echo 0 > "$BASE/state/claude/stall_checked_at"
refresh
wait_until '[[ $(cat "$BASE/state/claude/stall_checked_at") != 0 ]]'
sleep 0.3
check "marked: not sent again"              '[[ $(count scheduler-stalled notify-attempts) == 2 ]]'

# 別のエージェントの予約が動いても、Claude Code の予約が止まっていることに変わりはない
cp_run scheduled codex >/dev/null 2>&1
check "another agent's run does not clear it" '[[ -e "$BASE/state/claude/notified-stalled" && $(count recovered notify-attempts) == 0 ]]'

echo ok > "$CP_TEST/claude-mode"
cp_run scheduled claude >/dev/null
check "a run clears the stall, says so"     '[[ ! -e "$BASE/state/claude/notified-stalled" && $(count recovered notify-delivered) == 1 ]]'
check "status shows the last run"           '[[ $(cp_run status) == *"Last run      : 20"* ]]'

# ======================================================================
section "a slow stall check never holds up the status line"

# flock のない macOS と同じ mkdir のロックを Linux でも通すための PATH
NOFLOCK="$CP_TEST/noflock"
mkdir -p "$NOFLOCK"
for _f in /usr/local/bin/* /usr/bin/* /bin/*; do
    _n="$(basename "$_f")"
    [[ "$_n" == flock || -e "$NOFLOCK/$_n" ]] || ln -s "$_f" "$NOFLOCK/$_n"
done

for LOCKS in flock mkdir; do
    new_home "stalllock-$LOCKS"
    with_cs
    install_cp >/dev/null
    mkdir -p "$BASE/state/claude"
    if [[ "$LOCKS" == flock ]]; then LPATH="$FAKES:$PATH"; else LPATH="$FAKES:$NOFLOCK"; fi

    # 遅い notifier: 停止チェックが走っている間を長く取る。次の読み取りに許す
    # 5 秒より十分長く、遅い bash 3.2 が混んだ機械で動いても取り違えない
    cat > "$BASE/notify.sh" <<'EOF'
#!/usr/bin/env bash
sleep 8
echo "$CP_EVENT" >> "$CP_TEST/notify-delivered"
EOF
    chmod +x "$BASE/notify.sh"

    stall_reading() {
        printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$(( $(date +%s) + 3600 ))" |
            HOME="$H" PATH="$LPATH" tmo "$1" "$CP" observe claude >/dev/null 2>&1
    }

    # at が予約を受け付けず、期限切れの予約も取り消せない（atd の spool に
    # 書けないなど）。読み取りのたびに予約を試みて失敗し、停止チェックが起きる
    echo $(( $(date +%s) - 400 )) > "$BASE/state/claude/at_target"
    echo "$CP scheduled" > "$QUEUE/5"
    echo 5 > "$BASE/state/claude/at_job"
    touch "$CP_TEST/at-refuse"

    stall_reading 10
    wait_until '[[ -e "$BASE/state/claude/stall_checked_at" ]]'
    stall_reading 5; rc=$?
    check "$LOCKS: the next reading is not kept waiting" '[[ $rc == 0 ]]'

    # 生きている別のプロセスが持つロックを、停止チェックの終わりに消してはならない
    sleep 30 &
    holder=$!
    mkdir -p "$BASE/state/claude/schedule.lock.d"
    echo "$holder" > "$BASE/state/claude/schedule.lock.d/pid"
    # notifier は 8 秒かかる。wait_until 一回は 3 秒までなので、四回まで待つ
    for _ in 1 2 3 4; do
        wait_until '[[ $(count scheduler-stalled notify-delivered) == 1 ]]' && break
    done
    sleep 0.3
    check "$LOCKS: the stall check ran"                   '[[ $(count scheduler-stalled notify-delivered) == 1 ]]'
    check "$LOCKS: and left others' locks alone"          '[[ -e "$BASE/state/claude/schedule.lock.d/pid" ]]'
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    rm -rf "$BASE/state/claude/schedule.lock.d" "$CP_TEST/at-refuse"
    install_cp uninstall >/dev/null
done

# ======================================================================
section "processes an agent leaves behind do not hold the warmup lock"

new_home warmlock
echo '{}' > "$S"
install_cp >/dev/null

# エージェントが残した子プロセスが、次の warmup を締め出さない
echo child > "$CP_TEST/codex-mode"
cp_run warmup codex >/dev/null 2>&1
cp_run warmup codex >/dev/null 2>&1
check "a child left behind does not skip the next warmup" '[[ $(( $(wc -l < "$CP_TEST/codex-runs") )) == 2 ]]'
install_cp uninstall >/dev/null

# ======================================================================
section "a queued run does not depend on the session that queued it"

new_home atenv
with_cs
install_cp >/dev/null
PROJ="$CP_TEST/project-atenv"
mkdir -p "$PROJ"
rm -f "$CP_TEST/at-cwd" "$CP_TEST/at-env"
( cd "$PROJ" &&
  printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$(( $(date +%s) + 3600 ))" |
      in_home env TMUX=/tmp/tmux-0/default,1,0 TMUX_PANE=%3 CLAUDECODE=1 GITHUB_TOKEN=secret \
          HTTPS_PROXY=http://proxy:3128 "$CP" observe claude mod >/dev/null )
rm -rf "$PROJ"
check "queued from /, not the session's directory" '[[ $(our_jobs) == 1 && $(cat "$CP_TEST/at-cwd") == / ]]'
check "without the session's own variables"        '! grep -Eq "^(TMUX|TMUX_PANE|CLAUDECODE|FLUID_IN_STATUSLINE)=" "$CP_TEST/at-env"'
check "nor any token it had (at keeps them on disk)" '! grep -q "^GITHUB_TOKEN=" "$CP_TEST/at-env"'
check "but with what an agent needs to run"        'grep -qx "HOME=$H" "$CP_TEST/at-env" && grep -q "^PATH=$FAKES:" "$CP_TEST/at-env" && grep -qx "HTTPS_PROXY=http://proxy:3128" "$CP_TEST/at-env"'
check "state and log readable by the user alone"   '[[ -z $(find "$BASE" -perm -004 -o -perm -040 | head -1) ]]'

# 番号が使い回されて、他人のジョブが同じ番号になった（root の atq には全員の
# ジョブが並ぶ）。予約し直しても、それを自分のものとして消さない
other="$(cat "$BASE/state/claude/at_job")"
printf '# owner=someoneelse\n/home/someoneelse/.fluid/fluid.sh scheduled claude\n' > "$QUEUE/$other"
printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$(( $(date +%s) + 7200 ))" |
    cp_run observe claude mod
check "a reused job number of another user's is left alone" '[[ -e "$QUEUE/$other" && $(cat "$BASE/state/claude/at_job") != "$other" ]]'
install_cp uninstall >/dev/null

# ======================================================================
section "a second agent keeps its own window, schedule and failures"

new_home multi
with_cs
NOW="$(date +%s)"
codex_log "$(( NOW + 1800 ))" "$(( NOW + 200000 ))"
install_cp >/dev/null

check "every installed agent found"  '[[ $(cp_run providers | grep -c installed) == 3 ]]'
check "codex planned from its log"   '[[ $(cat "$BASE/state/codex/at_target") == $(( NOW + 1815 )) ]]'
check "window length from its report" '[[ $(cat "$BASE/state/codex/window_seconds") == 18000 ]]'
check "its long window too"          '[[ $(cat "$BASE/state/codex/long_used_percent") == 13 ]]'
check "claude waits for a reading"   '[[ ! -e "$BASE/state/claude/at_target" ]]'
check "one job each so far"          '[[ $(our_jobs) == 1 ]]'

printf '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":%s}}}' "$(( NOW + 600 ))" | cp_run observe claude >/dev/null
check "claude planned on its own"    '[[ $(cat "$BASE/state/claude/at_target") == $(( NOW + 615 )) ]]'
check "codex plan untouched"         '[[ $(cat "$BASE/state/codex/at_target") == $(( NOW + 1815 )) ]]'
check "a job each now"               '[[ $(our_jobs) == 2 ]]'

# まだ開いている窓（誰かが使った）: warmup せず、その reset に予約し直す
codex_log "$(( NOW + 900 ))" "$(( NOW + 200000 ))"
cp_run scheduled codex >/dev/null 2>&1
check "an open window is not warmed up again" '[[ ! -e "$CP_TEST/codex-runs" && $(cat "$BASE/state/codex/at_target") == $(( NOW + 915 )) ]]'

codex_log "$(( NOW - 60 ))" "$(( NOW + 200000 ))"
cp_run scheduled codex >/dev/null 2>&1
check "codex warmed up with its own command" 'grep -q -- "exec --skip-git-repo-check -s read-only --ephemeral" "$CP_TEST/codex-runs"'
touch "$CP_TEST/codex-old"
cp_run warmup codex >/dev/null 2>&1
rm -f "$CP_TEST/codex-old"
check "and without --ephemeral where codex lacks it" '[[ $(tail -1 "$CP_TEST/codex-runs") == "exec --skip-git-repo-check -s read-only Reply only OK." ]]'
check "claude was not run"           '[[ $(count run claude-runs) == 0 ]]'
check "codex estimate uses its window" '[[ $(cat "$BASE/state/codex/at_reason") == estimated-next-reset ]]'

echo fail > "$CP_TEST/claude-mode"
cp_run scheduled claude >/dev/null 2>&1
check "failures counted per agent"   '[[ $(cat "$BASE/state/claude/failure_count") == 1 && $(cat "$BASE/state/codex/failure_count") == 0 ]]'

install_cp uninstall >/dev/null
check "uninstall takes both"         '[[ ! -e "$BASE" && $(our_jobs) == 0 ]]'

# ======================================================================
section "a scheduler that fails for a moment does not lose the plan"

new_home transact
echo '{}' > "$S"
install_cp >/dev/null
make_notifier
T="$(( $(date +%s) + 3600 ))"
reading_at() {
    printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$1" | cp_run observe claude mod
}
reading_at "$T"
job="$(cat "$BASE/state/claude/at_job")"

# The same reset reported a few seconds apart keeps the job it has
reading_at "$(( T + 2 ))"
reading_at "$(( T - 3 ))"
check "a reset that jitters by seconds keeps its job" '[[ $(cat "$BASE/state/claude/at_job") == "$job" && $(our_jobs) == 1 ]]'

touch "$CP_TEST/at-refuse"
reading_at "$(( T + 600 ))"
check "a refused job leaves the planned one queued" '[[ -e "$QUEUE/$job" && $(cat "$BASE/state/claude/at_job") == "$job" && $(cat "$BASE/state/claude/at_target") == $(( T + 15 )) ]]'
wait_until '[[ $(count schedule-failed notify-delivered) == 1 ]]'
check "and says so"                                 '[[ $(count schedule-failed notify-delivered) == 1 ]]'

# 失敗したのが最後のエージェントでなくても、失敗として返す
echo 999 > "$BASE/state/claude/at_job"
cp_run reschedule >/dev/null 2>&1; rc=$?
check "reschedule fails when any agent could not be planned" '[[ $rc != 0 ]]'
echo "$job" > "$BASE/state/claude/at_job"

rm -f "$CP_TEST/at-refuse"
reading_at "$(( T + 600 ))"
wait_until '[[ $(count recovered notify-delivered) == 1 ]]'
check "once it works again: replaced, and said so" '[[ ! -e "$QUEUE/$job" && $(our_jobs) == 1 && $(count recovered notify-delivered) == 1 ]]'

# warmup の間に届いた公式の reset を、見積もりで上書きしない
echo slow > "$CP_TEST/claude-mode"
cp_run warmup claude >/dev/null 2>&1 &
warmer=$!
wait_until '[[ -s "$CP_TEST/claude-runs" ]]'
reading_at "$(( T + 1200 ))"
wait "$warmer"
check "a reading during a warmup outlives its estimate" '[[ $(cat "$BASE/state/claude/at_target") == $(( T + 1215 )) && $(cat "$BASE/state/claude/at_reason") == official-reset ]]'

# A stale reading (its reset already past) plans a run that finds this
# warmup busy and does nothing, so the estimate still has to follow
: > "$CP_TEST/claude-runs"
cp_run warmup claude >/dev/null 2>&1 &
warmer=$!
wait_until '[[ -s "$CP_TEST/claude-runs" ]]'
reading_at "$(( $(date +%s) - 3600 ))"
wait "$warmer"
check "a stale reading during a warmup leaves the next window planned" '[[ $(cat "$BASE/state/claude/at_reason") == estimated-next-reset && $(cat "$BASE/state/claude/at_target") -gt $(date +%s) && $(our_jobs) == 1 ]]'
install_cp uninstall >/dev/null

# npx は node_modules/.bin に相対のリンクを置く。readlink -f のない macOS でも
# 通知の見本まで入る
new_home npx
echo '{}' > "$S"
NPX="$CP_TEST/npx/node_modules"
mkdir -p "$NPX/fluid-agents" "$NPX/.bin" "$CP_TEST/bsd"
cp "$INSTALLER" "$NPX/fluid-agents/"
cp -R "$ROOT/notify" "$NPX/fluid-agents/"
ln -sf ../fluid-agents/install-fluid.sh "$NPX/.bin/fluid-agents"
cat > "$CP_TEST/bsd/readlink" <<'BSD'
#!/usr/bin/env bash
[[ "$1" == -f ]] && { echo "readlink: illegal option -- f" >&2; exit 1; }
exec /usr/bin/readlink "$@"
BSD
chmod +x "$CP_TEST/bsd/readlink"
( cd "$H" && HOME="$H" PATH="$CP_TEST/bsd:$FAKES:$PATH" bash "$NPX/.bin/fluid-agents" >/dev/null 2>&1 ); rc=$?
check "npx through a relative link: installs in full" '[[ $rc == 0 ]] && compgen -G "$BASE/notify/*.sample" >/dev/null'
install_cp uninstall >/dev/null

# ======================================================================
section "an agent that has gone missing is reported, not retried every minute"

new_home missing
with_cs
install_cp >/dev/null
make_notifier
rm -f "$CP_TEST/claude-runs"
HOME="$H" PATH="$NOCLAUDE_PATH" "$CP" scheduled claude >/dev/null 2>&1
check "no warmup attempted"        '[[ ! -e "$CP_TEST/claude-runs" && ! -e "$BASE/state/claude/failure_count" ]]'
check "looked at again in an hour" '[[ $(cat "$BASE/state/claude/at_reason") == agent-missing && $(cat "$BASE/state/claude/at_target") -ge $(( $(date +%s) + 3500 )) ]]'
check "and reported once"          '[[ $(count agent-missing notify-delivered) == 1 ]]'
HOME="$H" PATH="$NOCLAUDE_PATH" "$CP" scheduled claude >/dev/null 2>&1
check "not reported again"         '[[ $(count agent-missing notify-attempts) == 1 ]]'
cp_run scheduled claude >/dev/null 2>&1
check "back again: says so"        '[[ $(count recovered notify-delivered) == 1 && ! -e "$BASE/state/claude/notified-missing" ]]'

# 更新の時だけ PATH から見えなかったエージェントも、予約を失わず、status にも出る
target="$(cat "$BASE/state/claude/at_target")"
HOME="$H" PATH="$NOCLAUDE_PATH" bash "$INSTALLER" >/dev/null 2>&1
check "an upgrade keeps the plan of an agent off PATH" '[[ $(cat "$BASE/state/claude/at_target") == "$target" ]] && grep -lF "scheduled claude" "$QUEUE"/* >/dev/null 2>&1'
check "and status still shows it, missing"             '[[ $(HOME="$H" PATH="$NOCLAUDE_PATH" "$CP" status) == *"[claude]"*"NOT FOUND on PATH"* ]]'
check "an agent with nothing yet: no readings"         '[[ $(cp_run status) == *"Readings      : none yet"* ]]'

# warmup はどこから呼ばれても / で動く
PROJ="$CP_TEST/project-warm"
mkdir -p "$PROJ"
( cd "$PROJ" && cp_run warmup codex >/dev/null 2>&1 )
check "warmups run in /"           '[[ $(cat "$CP_TEST/codex-cwd") == / ]]'
install_cp uninstall >/dev/null

# ======================================================================
section "an agent with its own settings file is wrapped there"

new_home agy
with_cs
mkdir -p "$(dirname "$AGYS")"
printf '{"model":"gemini","colorScheme":"dark","statusLine":{"type":"command","command":"%s"}}\n' "$FAKES/cs" > "$AGYS"
cp "$S" "$CS"
install_cp >/dev/null

check "agy found"                    '[[ $(cp_run providers | grep -c agy) == 1 ]]'
check "wrapped in its own settings"  '[[ $(jq -r .statusLine.command "$AGYS") == "$CP statusline agy" ]]'
check "its other settings untouched" '[[ $(jq -r .model "$AGYS") == gemini && $(jq -r .colorScheme "$AGYS") == dark ]]'
check "Claude Code's settings left alone" '[[ $(jq -r .statusLine.command "$CS") == "$FAKES/cs" ]] && ! grep -qF "$MARKER" "$CS"'

NOW="$(date +%s)"
RESET="$(TZ=UTC tdate "$(( NOW + 1200 ))" '+%Y-%m-%dT%H:%M:%SZ')"
WEEK="$(TZ=UTC tdate "$(( NOW + 400000 ))" '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"quota":{"gemini-5h":{"remaining_fraction":1,"reset_time":"%s"},"3p-5h":{"remaining_fraction":0.75,"reset_time":"%s"},"gemini-weekly":{"remaining_fraction":0.9,"reset_time":"%s"}}}' \
    "$RESET" "$RESET" "$WEEK" | cp_run observe agy >/dev/null

check "remaining fraction becomes used" '[[ $(cat "$BASE/state/agy/used_percent") == 25 ]]'
check "RFC 3339 becomes an epoch"       '[[ $(cat "$BASE/state/agy/resets_at") == $(( NOW + 1200 )) ]]'
check "long window read too"            '[[ $(cat "$BASE/state/agy/long_used_percent") == 10 ]]'
check "planned from its own reading"    '[[ $(cat "$BASE/state/agy/at_target") == $(( NOW + 1215 )) ]]'

# 週の窓を報告しなくなった読み取り: 古い週の値を残さない。何も報告しない
# 読み取り（まだ使っていないセッション）は何も変えない
printf '{"quota":{"gemini-5h":{"remaining_fraction":0.5,"reset_time":"%s"}}}' "$RESET" | cp_run observe agy >/dev/null
check "a long window no longer reported is dropped" '[[ ! -e "$BASE/state/agy/long_used_percent" && $(cat "$BASE/state/agy/used_percent") == 50 ]]'
printf '{"quota":{}}' | cp_run observe agy >/dev/null
check "a reading of nothing keeps what is known"    '[[ $(cat "$BASE/state/agy/resets_at") == $(( NOW + 1200 )) ]]'
printf '{"rate_limits":{"five_hour":{"used_percentage":"50 percent","resets_at":%s}}}' "$(( NOW + 1200 ))" | cp_run observe claude mod >/dev/null
check "only numbers are stored"                     '[[ ! -e "$BASE/state/claude/used_percent" && $(cat "$BASE/state/claude/resets_at") == $(( NOW + 1200 )) ]]'

cp_run scheduled agy >/dev/null 2>&1
check "warmed up with its own command"  'grep -q -- "-p Reply only OK." "$CP_TEST/agy-runs"'

out="$(install_cp uninstall)"
check "its status line restored"        '[[ $(jq -r .statusLine.command "$AGYS") == "$FAKES/cs" ]]'
check "claude status line restored"     '[[ $(jq -r .statusLine.command "$S") == "$FAKES/cs" ]]'
check "both settings backed up"         '[[ $(( $(compgen -G "$AGYS.fluid-uninstall-backup.*" | wc -l) )) == 1 ]]'

# ======================================================================
section "anchor arithmetic, on fixed dates"

# Run apply_anchor straight from the generated script. In a subshell, since
# sourcing it would overwrite BASE and friends.
anchor_cases() {
    local lib="$CP_TEST/lib.sh"
    sed -n "/^cat > \"\$STAGE\/fluid.sh\" <<'FLUID_SCRIPT'$/,/^FLUID_SCRIPT$/p" "$INSTALLER" |
        sed '1d;$d' | sed '/^case "\${1:-}" in$/,$d' > "$lib"
    HOME="$CP_TEST/home-fn"
    mkdir -p "$HOME"
    source "$lib"
    ANCHOR="$CP_TEST/anchor-fn"

    run() {
        printf '%s\n' "$2" > "$ANCHOR"
        printf '%s @ %s|%s|%s\n' "$1" "$2" \
            "$(fmt_time "$(apply_anchor 18000 "$(parse_time "$1")")" '+%F %H:%M')" "$3"
    }

    run "2026-09-21 03:00" "06:00" "2026-09-21 06:00"   # held
    run "2026-09-21 01:30" "06:00" "2026-09-21 06:00"   # held
    run "2026-09-21 06:00" "06:00" "2026-09-21 06:00"   # starts on it
    run "2026-09-21 06:01" "06:00" "2026-09-21 06:01"   # just missed it
    run "2026-09-21 07:00" "06:00" "2026-09-21 07:00"   # already past
    run "2026-09-21 23:00" "01:00" "2026-09-22 01:00"   # held over midnight
    run "2026-09-21 20:00" "01:00" "2026-09-21 20:00"   # anchor is the window end
    run "2026-09-21 20:01" "01:00" "2026-09-22 01:00"   # a minute inside the end
    run "2026-09-21 21:00" "00:00" "2026-09-22 00:00"   # midnight anchor, held
    run "2026-09-21 00:30" "00:00" "2026-09-21 00:30"   # midnight anchor, missed
    # 夏時間に入る日の前夜: 23 時間の日をまたいでも、日付を一つ飛ばさない
    TZ=America/New_York run "2026-03-07 23:30" "01:00" "2026-03-08 01:00"
    run "2026-09-21 03:00" "nonsense" "2026-09-21 03:00"
    run "2026-09-21 03:00" "" "2026-09-21 03:00"
}

while IFS='|' read -r name actual expected; do
    check "$name -> $expected (got $actual)" '[[ "$actual" == "$expected" ]]'
done < <(anchor_cases)

# ======================================================================
section "an anchor time holds a window back instead of running across it"

new_home anchor
with_cs
install_cp >/dev/null

# Feed observe a reset time, as a status line refresh would
observe_reset() {
    printf '{"rate_limits":{"five_hour":{"resets_at":%s,"used_percentage":10}}}' "$1" | cp_run observe claude >/dev/null
}
# The HH:MM, and the epoch second, of a moment given as an offset from now
at_hhmm() { tdate "$(( NOW + $1 ))" '+%H:%M'; }
at_epoch() { echo $(( (NOW + $1) / 60 * 60 )); }

check "no anchor by default"          '[[ $(cp_run anchor) == "Anchor: not set" ]]'
check "status says not set"           '[[ $(cp_run status) == *"Anchor          : not set"* ]]'

NOW="$(date +%s)"
cp_run anchor "$(at_hhmm 7200)" >/dev/null
check "anchor set and shown"          '[[ $(cat "$BASE/anchor") == $(at_hhmm 7200) && $(cp_run status) == *"Anchor          : $(at_hhmm 7200)"* ]]'

cp_run anchor 25:00 >/dev/null 2>&1
rc=$?
check "rejects a bad time"            '[[ $rc == 2 && $(cat "$BASE/anchor") == $(at_hhmm 7200) ]]'

# A window due now would cover the anchor two hours out: hold it back
observe_reset $(( NOW + 45 ))
check "anchor inside the window: held" '[[ $(cat "$BASE/state/claude/at_target") == $(at_epoch 7200) && $(cat "$BASE/state/claude/at_reason") == anchor-hold ]]'

# An anchor beyond the end of the window changes nothing
cp_run anchor "$(at_hhmm 21600)" >/dev/null
observe_reset $(( NOW + 45 ))
check "anchor past the window: as planned" '[[ $(cat "$BASE/state/claude/at_target") == $(( NOW + 60 )) && $(cat "$BASE/state/claude/at_reason") == official-reset ]]'

# A window starting exactly on the anchor is already aligned. Clear the queue
# first, or arm_job would keep the previous plan for the very same moment.
cp_run anchor "$(at_hhmm 7200)" >/dev/null
rm -f "$QUEUE"/*
observe_reset $(( $(at_epoch 7200) - 15 ))
check "window starts on the anchor: kept" '[[ $(cat "$BASE/state/claude/at_target") == $(at_epoch 7200) && $(cat "$BASE/state/claude/at_reason") == official-reset ]]'

# Setting an anchor re-plans what is already scheduled
cp_run anchor off >/dev/null
observe_reset $(( NOW + 45 ))
check "cleared: opens as soon as it can" '[[ $(cat "$BASE/state/claude/at_target") == $(( NOW + 60 )) && $(cp_run anchor) == "Anchor: not set" ]]'
cp_run anchor "$(at_hhmm 7200)" >/dev/null
check "setting one re-plans the next run" '[[ $(cat "$BASE/state/claude/at_target") == $(at_epoch 7200) && $(cat "$BASE/state/claude/at_reason") == anchor-hold ]]'
check "only one job of ours is queued"    '[[ $(our_jobs) == 1 ]]'

# 押さえた後で外すと、押さえる前の時刻に戻る（次の読み取りを待たずに）
cp_run anchor off >/dev/null
check "clearing it undoes the hold at once" '[[ $(cat "$BASE/state/claude/at_target") == $(( NOW + 60 )) && $(cat "$BASE/state/claude/at_reason") == official-reset && $(our_jobs) == 1 ]]'
cp_run anchor "$(at_hhmm 7200)" >/dev/null

install_cp >/dev/null
check "upgrade keeps the anchor"      '[[ $(cat "$BASE/anchor") == $(at_hhmm 7200) ]]'
install_cp uninstall >/dev/null
check "uninstall removes it"          '[[ ! -e "$BASE" ]]'

# ======================================================================
section "a model the agent has dropped is replaced by its own default"

new_home model
with_cs
install_cp >/dev/null
make_notifier

last_args() { tail -1 "$CP_TEST/claude-args"; }

cp_run warmup claude >/dev/null
check "warms up with the cheap model"  '[[ $(last_args) == *"--model haiku"* ]]'
check "shown in status"                '[[ $(cp_run status) == *"Warmup model  : haiku"* ]]'
check "and by the model command"       '[[ $(cp_run model claude) == "claude     haiku" ]]'

# An ordinary failure must not be mistaken for a dead model
echo fail > "$CP_TEST/claude-mode"
cp_run warmup claude >/dev/null
check "plain failure: model kept"      '[[ ! -e "$BASE/state/claude/warmup_model" && $(count model-changed notify-attempts) == 0 ]]'

echo badmodel > "$CP_TEST/claude-mode"
rm -f "$CP_TEST/claude-runs"
cp_run warmup claude >/dev/null
check "dead model: retried without one" '[[ $(count run claude-runs) == 2 && $(last_args) != *--model* ]]'
check "the retry counts as a success"   '[[ $(cat "$BASE/state/claude/failure_count") == 0 ]]'
check "the fallback is remembered"      '[[ $(cat "$BASE/state/claude/warmup_model") == "-" ]]'
check "and announced once"              '[[ $(count model-changed notify-delivered) == 1 ]]'
check "status says agent default"       '[[ $(cp_run status) == *"Warmup model  : (agent default)"* ]]'

rm -f "$CP_TEST/claude-runs"
cp_run warmup claude >/dev/null
check "no second attempt at it"        '[[ $(count run claude-runs) == 1 && $(count model-changed notify-delivered) == 1 ]]'

echo ok > "$CP_TEST/claude-mode"
cp_run model claude sonnet >/dev/null
cp_run warmup claude >/dev/null
check "a model set by hand is used"    '[[ $(last_args) == *"--model sonnet"* ]]'
cp_run model claude auto >/dev/null
cp_run warmup claude >/dev/null
check "auto goes back to the cheap one" '[[ $(last_args) == *"--model haiku"* ]]'
check "an unknown agent is refused"     '! cp_run model nosuch x >/dev/null 2>&1'

install_cp >/dev/null
cp_run model claude default >/dev/null
install_cp >/dev/null
check "upgrade keeps the choice"       '[[ $(cat "$BASE/state/claude/warmup_model") == "-" ]]'
install_cp uninstall >/dev/null

# ======================================================================
section "the Claude Code plugin reads through its hooks module and installs the rest"

v="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$INSTALLER")"
check "one version everywhere" '[[ -n $v && $(jq -r .version "$ROOT/package.json") == "$v" && $(jq -r .version "$ROOT/.claude-plugin/plugin.json") == "$v" && $(jq -r ".metadata.version, .plugins[0].version" "$ROOT/.claude-plugin/marketplace.json" | sort -u) == "$v" ]]'
check "marketplace names the plugin" '[[ $(jq -r .plugins[0].name "$ROOT/.claude-plugin/marketplace.json") == $(jq -r .name "$ROOT/.claude-plugin/plugin.json") ]]'
check "the plugin carries the module and no command hooks" '[[ $(jq -c .modules "$ROOT/hooks/hooks.json") == "[\"./register.ts\"]" ]] && ! jq -e .hooks "$ROOT/hooks/hooks.json" >/dev/null'

new_home plugin
with_cs
cp "$S" "$CS"
before="$(cksum < "$CS")"
check "status before install says so" '[[ $(in_home "$ROOT/scripts/entry.sh" status) == *"/fluid:install"* ]]'
out="$(in_home env FLUID_MOD=1 "$ROOT/scripts/entry.sh" install)"
check "plugin install: Claude Code settings untouched"  '[[ $(cksum < "$CS") == "$before" ]]'
check "plugin install: no missing-module notice"        '[[ $out != *"Claude Code: "* ]]'
check "plugin install: other agents still wrapped"      '[[ $(jq -r .statusLine.command "$S") == "$CP statusline agy" ]]'

in_home "$ROOT/scripts/entry.sh" anchor '07:00;touch x' >/dev/null; rc=$?
check "anchor refuses anything but HH:MM|off" '[[ $rc == 2 && ! -e "$BASE/anchor" ]]'
in_home "$ROOT/scripts/entry.sh" anchor 07:30 >/dev/null
check "anchor takes a time"              '[[ $(cat "$BASE/anchor") == 07:30 ]]'
rm -f "$BASE/anchor"

T="$(( $(date +%s) + 3600 ))"
printf '{"rate_limits":{"five_hour":{"used_percentage":33,"resets_at":%s},"seven_day":{"used_percentage":22,"resets_at":%s}}}' "$T" "$(( T + 86400 ))" |
    cp_run observe claude mod
check "a module reading plans the next window"          '[[ $(cat "$BASE/state/claude/at_target") == $(( T + 15 )) && $(our_jobs) == 1 ]]'
check "status names where the readings come from"       '[[ $(cp_run status) == *"Readings      : hooks module, last 20"* ]]'
check "status has no tmux resume any more"              '[[ $(cp_run status) != *"Resume        :"* ]]'

cp_run notify resume-failed "It is waiting for you."; rc=$?
check "an alert with no notifier yet fails, to be sent again" '[[ $rc != 0 ]]'
make_notifier
cp_run log claude "Sending continue to the stopped session, attempt 1"
cp_run notify resume-failed "It is waiting for you."; rc=$?
check "the module's log lines reach the log"            'grep -q "\[claude\] Sending continue to the stopped session, attempt 1" "$BASE/fluid.log"'
check "and its alerts the notifier"                     '[[ $rc == 0 && $(count resume-failed notify-delivered) == 1 ]]'

# 予約した at ジョブに、モジュールの印を持ち込まない
rm -f "$CP_TEST/at-env"
printf '{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":%s}}}' "$(( T + 600 ))" |
    in_home env FLUID_MOD=1 "$CP" observe claude mod
check "a queued run carries no module mark"             '[[ -s "$CP_TEST/at-env" ]] && ! grep -q "^FLUID_MOD=" "$CP_TEST/at-env"'
install_cp uninstall >/dev/null
check "uninstall leaves Claude Code settings as found"  '[[ $(cksum < "$CS") == "$before" && ! -e "$BASE" ]]'

# モジュールが読み込まれていないセッション、プラグインなしのインストール: 状態栏は包まず、そう伝える
new_home nomodule
printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$FAKES/cs" > "$CS"
before="$(cksum < "$CS")"
out="$(in_home "$ROOT/scripts/entry.sh" install)"
check "no module: Claude Code settings untouched"       '[[ $(cksum < "$CS") == "$before" ]]'
check "no module: says nothing is planned until a reading" '[[ $out == *"hooks module did not load"* && $out == *"first reading"* ]]'
install_cp uninstall >/dev/null
out="$(install_cp)"
check "no plugin: Claude Code settings untouched"       '[[ $(cksum < "$CS") == "$before" ]]'
check "no plugin: points at the plugin"                 '[[ $out == *"/plugin install fluid"* && $out == *"nothing is planned"* ]]'
cp_run rate-limit claude </dev/null >/dev/null 2>&1; rc=$?
check "no plugin: the old hook command is gone"         '[[ $rc == 2 ]]'
install_cp uninstall >/dev/null

# ======================================================================
section "what versions before 0.3.0 put in Claude Code's settings comes out"

new_home legacy
cat > "$CS" <<EOF
{
  "model": "opus",
  "statusLine": {"type": "command", "command": "$BASE/fluid.sh statusline claude", "refreshInterval": 1},
  "hooks": {
    "StopFailure": [{"matcher": "rate_limit", "hooks": [{"type": "command", "command": "$BASE/fluid.sh rate-limit claude"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "/opt/audit"}]}]
  }
}
EOF
mkdir -p "$BASE/state/claude"
echo "$FAKES/cs" > "$BASE/state/claude/original-statusline-command"
install_cp >/dev/null
check "upgrade: Claude Code's own status line is back"  '[[ $(jq -r .statusLine.command "$CS") == "$FAKES/cs" && $(jq .statusLine.refreshInterval "$CS") == 1 ]]'
check "upgrade: the StopFailure hook is gone"           '! grep -qF "$MARKER" "$CS" && [[ $(jq -c ".hooks | keys" "$CS") == "[\"PreToolUse\"]" ]]'
check "upgrade: everything else kept"                   '[[ $(jq -r .model "$CS") == opus ]]'
install_cp uninstall >/dev/null

# ======================================================================
section "unsupported systems are told so before anything changes"

for k in MINGW64_NT-10.0 FreeBSD; do
    new_home "os-$k"
    with_cs
    echo "$k" > "$CP_TEST/uname"
    out="$(install_cp 2>&1)"; rc=$?
    check "$k: refused"        '[[ $rc == 1 && ! -e "$BASE" && $(jq -r .statusLine.command "$S") == "$FAKES/cs" ]]'
    case "$k" in
        MINGW*) check "$k: points to WSL" '[[ $out == *"WSL"* ]]' ;;
    esac
done
rm -f "$CP_TEST/uname"

# ======================================================================
section "macOS queues runs as one-shot launchd agents"

new_home mac
with_cs
echo Darwin > "$CP_TEST/uname"
rm -f "$CP_TEST/launchctl-log" "$CP_TEST/launchctl-refuse"
AGENTS="$H/Library/LaunchAgents"
mac() {
    in_home env -u FLUID_SCHEDULER "$@"
}
plists() {
    echo $(( $(ls "$AGENTS"/io.github.mrjasonzhou.fluid.*.plist 2>/dev/null | wc -l) ))
}
reading() {
    printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}}}' "$1" |
        mac "$CP" observe claude
}

mac bash "$INSTALLER" >/dev/null 2>&1; rc=$?
check "installs on macOS"                 '[[ $rc == 0 && $(jq -r .statusLine.command "$S") == "$CP statusline agy" ]]'
check "no at job"                         '[[ $(our_jobs) == 0 ]]'
check "status names launchd"              '[[ $(mac "$CP" status) == *"Scheduler       : launchd"* ]]'

T1=$(( $(date +%s) + 7200 ))
T1=$(( T1 - T1 % 60 + 20 ))               # 20 s past a minute, plus the 15 s of slack
reading "$T1"
P="$(ls "$AGENTS"/*.plist 2>/dev/null | head -1)"
job="$(cat "$BASE/state/claude/at_job")"
check "a reading queues one agent"        '[[ $(plists) == 1 && $P == *".$job.plist" ]]'
check "and loads it"                      'grep -q "^bootstrap gui/$(id -u) $P$" "$CP_TEST/launchctl-log"'
up=$(( (T1 + 15) / 60 * 60 + 60 ))
check "rounded up to the next minute"     'grep -q "<integer>$((10#$(tdate "$up" +%M)))</integer>" "$P" && [[ $job == "$up-"* ]]'
check "runs fluid.sh scheduled claude"    'grep -q "<string>$CP</string>" "$P" && grep -q "<string>scheduled</string>" "$P"'

reading "$(( T1 + 600 ))"
check "a new reading replaces it"         '[[ $(plists) == 1 && ! -e $P ]] && grep -q "^remove io.github.mrjasonzhou.fluid.$job$" "$CP_TEST/launchctl-log"'

# Run the agent the way launchd would: its own arguments, in order, and only
# the environment the plist gives it
P="$(ls "$AGENTS"/*.plist | head -1)"
ARGV=()
while IFS= read -r line; do ARGV+=("$line"); done < <(sed -n '/<key>ProgramArguments/,/<\/array>/s:.*<string>\(.*\)</string>.*:\1:p' "$P")
JOBPATH="$(sed -n 's:.*<key>PATH</key><string>\(.*\)</string>.*:\1:p' "$P")"
check "the plist carries the PATH it was queued with" '[[ $JOBPATH == "$FAKES:"* ]]'
check "it also runs at load, to catch up"       'grep -q "<key>RunAtLoad</key>" "$P"'
rm -f "$CP_TEST/claude-runs"
launchd_run() {
    env -i HOME="$H" CP_TEST="$CP_TEST" PATH="${JOBPATH:-/usr/bin:/bin:/usr/sbin:/sbin}" "$@"
}
# 読み込まれた直後（時刻の前）は何もしない
launchd_run "${ARGV[@]}"
check "before its time: waits"                 '[[ -e $P && ! -e "$CP_TEST/claude-runs" ]]'
# 時刻を過ぎていれば（逃した予約をログイン時に拾うときも）走る
ARGV[${#ARGV[@]}-1]=0
launchd_run "${ARGV[@]}"
check "the agent deletes itself and warms up" '[[ ! -e $P && $(count run claude-runs) == 1 ]]'
check "and queues the next window"        '[[ $(plists) == 1 ]]'

touch "$CP_TEST/launchctl-refuse"
reading "$(( T1 + 1200 ))"
check "a refused agent leaves only the plan it had" '[[ $(plists) == 1 ]] && grep -q "launchd refused" "$BASE/fluid.log"'
rm -f "$CP_TEST/launchctl-refuse"

reading "$(( T1 + 1800 ))"
mac bash "$INSTALLER" uninstall >/dev/null
check "uninstall removes the agents"      '[[ $(plists) == 0 && ! -e "$BASE" ]]'
rm -f "$CP_TEST/uname"

# ======================================================================
echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
