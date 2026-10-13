#!/usr/bin/env bash
# Integration tests for Fluid.
#
#   bash tests/run.sh
#
# Everything runs inside a throwaway directory: its own HOME, and fake claude,
# at, atq, atrm, systemctl, pgrep and tmux on PATH. The real at queue and
# settings.json are never touched. Needs jq, flock and timeout, which Claude
# Plus needs anyway.

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
q="$CP_TEST/queue"
if [[ "$1" == -c ]]; then
    cat "$q/$2" 2>/dev/null
    exit
fi
last="$(ls "$q" | sort -n | tail -1)"
n=$(( ${last:-0} + 1 ))
cat > "$q/$n"
echo "job $n at $2"
EOF

cat > "$FAKES/atq" <<'EOF'
#!/usr/bin/env bash
for f in "$CP_TEST/queue"/*; do
    [[ -e "$f" ]] && printf '%s\tThu Jan  1 00:00:00 2099 a user\n' "$(basename "$f")"
done
EOF

cat > "$FAKES/atrm" <<'EOF'
#!/usr/bin/env bash
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
echo "$*" >> "$CP_TEST/codex-runs"
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
s="$HOME/.claude/settings.json"
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

# Same, but slow, so the chain probe stays in place long enough to race with
cat > "$FAKES/slowreplace" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 2
printf Y
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

# tmux: a pane whose first process is named by a file, and keys sent to it
# collected in another
cat > "$FAKES/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *display-message*) [[ -s "$CP_TEST/tmux-pane-pid" ]] && cat "$CP_TEST/tmux-pane-pid" ;;
    *send-keys*)       echo "${@: -1}" >> "$CP_TEST/tmux-keys" ;;
    *)                 exit 1 ;;
esac
EOF

chmod +x "$FAKES"/*

# ---------------------------------------------------------------- helpers

new_home() {
    H="$CP_TEST/home-$1"
    rm -rf "$H"
    mkdir -p "$H/.claude"
    S="$H/.claude/settings.json"
    BASE="$H/.fluid"
    CP="$BASE/fluid.sh"
    ORIGFILE="$BASE/state/claude/original-statusline-command"
    rm -f "$QUEUE"/* "$CP_TEST"/claude-mode "$CP_TEST"/claude-runs "$CP_TEST"/claude-args "$CP_TEST"/codex-runs "$CP_TEST"/agy-runs "$CP_TEST"/notify-*
    AGYS="$H/.gemini/antigravity-cli/settings.json"
    echo up > "$CP_TEST/atd"
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
        in_home timeout 5 bash -c "$(jq -r .statusLine.command "$S")"
}

our_jobs() {
    grep -lF "$MARKER" "$QUEUE"/* 2>/dev/null | wc -l
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
check "wraps the status line"      '[[ $(jq -r .statusLine.command "$S") == "$CP statusline claude" ]]'
check "saves the original"         '[[ $(cat "$ORIGFILE") == "$FAKES/cs" ]]'
check "keeps statusLine siblings"  '[[ $(jq .statusLine.refreshInterval "$S") == 1 ]]'
check "adds the status line and one hook" '[[ $(grep -o "$MARKER" "$S" | wc -l) == 2 && $(jq -r ".hooks.StopFailure[0].matcher" "$S") == rate_limit ]]'
check "the hook names the agent"   '[[ $(jq -r ".hooks.StopFailure[0].hooks[0].command" "$S") == "$CP rate-limit claude" ]]'
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
check "upgrade: stray hooks of ours gone"  '[[ $(grep -o "$MARKER" "$S" | wc -l) == 2 && $(jq -c ".hooks | keys" "$S") == "[\"PreToolUse\",\"SessionEnd\",\"StopFailure\",\"UserPromptSubmit\"]" && $(jq ".hooks.StopFailure | length" "$S") == 1 ]]'
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

before="$(md5sum < "$S")"
out="$(install_cp uninstall)"
rc=$?
check "uninstall again: exit 0"          '[[ $rc == 0 ]]'
check "uninstall again: not installed"   '[[ $out == *"not installed"* ]]'
check "uninstall again: file untouched"  '[[ $(md5sum < "$S") == "$before" ]]'

new_home nosettings
install_cp uninstall >/dev/null
check "no settings.json: none created"   '[[ ! -e "$S" ]]'

new_home badjson
echo '{broken' > "$S"
before="$(md5sum < "$S")"
install_cp uninstall >/dev/null 2>&1
rc=$?
check "invalid JSON: refused"            '[[ $rc == 1 && $(md5sum < "$S") == "$before" ]]'

install_cp --help >/dev/null 2>&1; rc=$?
check "--help exits 0"                   '[[ $rc == 0 ]]'
install_cp bogus >/dev/null 2>&1; rc=$?
check "unknown action exits 2"           '[[ $rc == 2 ]]'

# ======================================================================
section "strip filter edge cases"

STRIP_FILTER="$(sed -n "/^STRIP_FILTER='$/,/^'$/p" "$INSTALLER" | sed '1d;$d')"
strip() {
    jq -cS --arg marker "$MARKER" --arg orig "${2:-}" "$STRIP_FILTER" <<< "$1"
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
for odd in '{"statusLine":"text"}' '{"hooks":[]}' '{"hooks":{"X":"s"}}' '{"hooks":{"X":[1,null]}}' '{"hooks":{"X":[{"hooks":"n"}]}}'; do
    check "odd shape passes through: $odd" '[[ $(strip "$odd") == "$(norm "$odd")" ]]'
done

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
before="$(md5sum < "$S")"
install_cp uninstall >/dev/null
check "uninstall again: still renders" '[[ $(render) == "X[CS]" && $(md5sum < "$S") == "$before" ]]'
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
    rm -f "$CP_TEST/claude-runs"
}

wait_for_probe() {
    local i
    for i in $(seq 1 60); do
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
wait "$installer"
check "scheduled run during probe still ran"    '[[ -s "$CP_TEST/claude-runs" ]]'
check "other calls during probe are not a hit"   '[[ $(cat "$CP_TEST/probe.out") != *pass-through* && ! -e "$BASE" ]]'

for sig in HUP TERM INT; do
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
    check "SIG$sig during probe: installer stops"          '[[ $rc != 0 ]]'
    check "SIG$sig during probe: real script restored"     'grep -q "^observe()" "$CP"'
    check "SIG$sig during probe: no temporary files left"  '! compgen -G "$BASE/.saved.*" >/dev/null && ! compgen -G "$BASE/.probe.*" >/dev/null'
    check "SIG$sig during probe: still installed"          '[[ -d "$BASE/state" ]]'
done

# ======================================================================
section "upgrade keeps runtime state; uninstall removes it"

new_home state
with_cs
install_cp >/dev/null
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

check "generated script never turns errexit on" \
    '! sed -n "/^cat > \"\$BIN\" <<.FLUID_SCRIPT.\$/,/^FLUID_SCRIPT\$/p" "$INSTALLER" | grep -qE "^\s*set -e"'

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

echo $(( $(date +%s) + 600 )) > "$BASE/state/claude/at_target"
refresh
sleep 0.5
check "target in the future: not looked at"  '[[ ! -e "$BASE/state/stall_checked_at" ]]'

echo $(( $(date +%s) - 400 )) > "$BASE/state/claude/at_target"
echo 99 > "$BASE/state/claude/at_job"
refresh
wait_until '[[ -e "$BASE/state/stall_checked_at" ]]'
sleep 0.3
check "overdue but no longer queued: quiet" '[[ $(count scheduler-stalled notify-attempts) == 0 ]]'

echo "$CP scheduled" > "$QUEUE/5"
echo 5 > "$BASE/state/claude/at_job"
rm -f "$BASE/state/stall_checked_at"
echo 1 > "$CP_TEST/notify-fail"
refresh
wait_until '[[ $(count scheduler-stalled notify-attempts) == 1 ]]'
check "overdue and queued: alert attempted" '[[ $(count scheduler-stalled notify-attempts) == 1 ]]'
check "failed send: not marked"             '[[ ! -e "$BASE/state/notified-stalled" ]]'
check "status flags the overdue run"        '[[ $(cp_run status) == *OVERDUE* ]]'

refresh
sleep 0.5
check "throttled: no second look straight away" '[[ $(count scheduler-stalled notify-attempts) == 1 ]]'

echo 0 > "$BASE/state/stall_checked_at"
refresh
wait_until '[[ $(count scheduler-stalled notify-delivered) == 1 ]]'
check "retry after grace: delivered, marked" '[[ $(count scheduler-stalled notify-delivered) == 1 && -e "$BASE/state/notified-stalled" ]]'

echo 0 > "$BASE/state/stall_checked_at"
refresh
wait_until '[[ $(cat "$BASE/state/stall_checked_at") != 0 ]]'
sleep 0.3
check "marked: not sent again"              '[[ $(count scheduler-stalled notify-attempts) == 2 ]]'

echo ok > "$CP_TEST/claude-mode"
cp_run scheduled claude >/dev/null
check "a run clears the stall, says so"     '[[ ! -e "$BASE/state/notified-stalled" && $(count recovered notify-delivered) == 1 ]]'
check "status shows the last run"           '[[ $(cp_run status) == *"Last run      : 20"* ]]'

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

cp_run scheduled codex >/dev/null 2>&1
check "codex warmed up with its own command" 'grep -q -- "exec --skip-git-repo-check -s read-only" "$CP_TEST/codex-runs"'
check "claude was not run"           '[[ $(count run claude-runs) == 0 ]]'
check "codex estimate uses its window" '[[ $(cat "$BASE/state/codex/at_reason") == estimated-next-reset ]]'

echo fail > "$CP_TEST/claude-mode"
cp_run scheduled claude >/dev/null 2>&1
check "failures counted per agent"   '[[ $(cat "$BASE/state/claude/failure_count") == 1 && $(cat "$BASE/state/codex/failure_count") == 0 ]]'

install_cp uninstall >/dev/null
check "uninstall takes both"         '[[ ! -e "$BASE" && $(our_jobs) == 0 ]]'

# ======================================================================
section "an agent with its own settings file is wrapped there"

new_home agy
with_cs
mkdir -p "$(dirname "$AGYS")"
printf '{"model":"gemini","colorScheme":"dark","statusLine":{"type":"command","command":"%s"}}\n' "$FAKES/cs" > "$AGYS"
install_cp >/dev/null

check "agy found"                    '[[ $(cp_run providers | grep -c agy) == 1 ]]'
check "wrapped in its own settings"  '[[ $(jq -r .statusLine.command "$AGYS") == "$CP statusline agy" ]]'
check "its other settings untouched" '[[ $(jq -r .model "$AGYS") == gemini && $(jq -r .colorScheme "$AGYS") == dark ]]'
check "claude wrapped separately"    '[[ $(jq -r .statusLine.command "$S") == "$CP statusline claude" ]]'

NOW="$(date +%s)"
RESET="$(date -u -d "@$(( NOW + 1200 ))" '+%Y-%m-%dT%H:%M:%SZ')"
WEEK="$(date -u -d "@$(( NOW + 400000 ))" '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"quota":{"gemini-5h":{"remaining_fraction":1,"reset_time":"%s"},"3p-5h":{"remaining_fraction":0.75,"reset_time":"%s"},"gemini-weekly":{"remaining_fraction":0.9,"reset_time":"%s"}}}' \
    "$RESET" "$RESET" "$WEEK" | cp_run observe agy >/dev/null

check "remaining fraction becomes used" '[[ $(cat "$BASE/state/agy/used_percent") == 25 ]]'
check "RFC 3339 becomes an epoch"       '[[ $(cat "$BASE/state/agy/resets_at") == $(( NOW + 1200 )) ]]'
check "long window read too"            '[[ $(cat "$BASE/state/agy/long_used_percent") == 10 ]]'
check "planned from its own reading"    '[[ $(cat "$BASE/state/agy/at_target") == $(( NOW + 1215 )) ]]'

cp_run scheduled agy >/dev/null 2>&1
check "warmed up with its own command"  'grep -q -- "-p Reply only OK." "$CP_TEST/agy-runs"'

out="$(install_cp uninstall)"
check "its status line restored"        '[[ $(jq -r .statusLine.command "$AGYS") == "$FAKES/cs" ]]'
check "claude status line restored"     '[[ $(jq -r .statusLine.command "$S") == "$FAKES/cs" ]]'
check "both settings backed up"         '[[ $(compgen -G "$AGYS.fluid-uninstall-backup.*" | wc -l) == 1 ]]'

# ======================================================================
section "anchor arithmetic, on fixed dates"

# Run apply_anchor straight from the generated script. In a subshell, since
# sourcing it would overwrite BASE and friends.
anchor_cases() {
    local lib="$CP_TEST/lib.sh"
    sed -n "/^cat > \"\$BIN\" <<'FLUID_SCRIPT'$/,/^FLUID_SCRIPT$/p" "$INSTALLER" |
        sed '1d;$d' | sed '/^case "\${1:-}" in$/,$d' > "$lib"
    HOME="$CP_TEST/home-fn"
    mkdir -p "$HOME"
    source "$lib"
    ANCHOR="$CP_TEST/anchor-fn"

    run() {
        printf '%s\n' "$2" > "$ANCHOR"
        printf '%s @ %s|%s|%s\n' "$1" "$2" \
            "$(date -d "@$(apply_anchor 18000 "$(date -d "$1" +%s)")" '+%F %H:%M')" "$3"
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
at_hhmm() { date -d "@$(( NOW + $1 ))" '+%H:%M'; }
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
section "a session still stopped after the reset is resumed in its pane"

new_home resume
with_cs
make_notifier
install_cp >/dev/null
sleep 300 & PANE_A=$!
sleep 300 & PANE_B=$!
echo "$PANE_A" > "$CP_TEST/tmux-pane-pid"
rm -f "$CP_TEST/tmux-keys"
T="$H/transcript.jsonl"
PENDING="$BASE/state/claude/pending/s1.json"
printf '%s\n' '{"type":"user","message":{"content":"go"}}' \
    '{"type":"assistant","error":"rate_limit","isApiErrorMessage":true}' \
    '{"type":"system","subtype":"turn_duration"}' > "$T"
echo "$(( $(date +%s) - 10 ))" > "$BASE/state/claude/resets_at"
hit() {
    printf '{"session_id":"s1","transcript_path":"%s"}' "$T" |
        in_home env "$@" "$CP" rate-limit claude
}
due_now() {
    jq '.due = 0' "$PENDING" > "$PENDING.t" && mv "$PENDING.t" "$PENDING"
}
keys() {
    cat "$CP_TEST/tmux-keys" 2>/dev/null | tr '\n' ' '
}

hit -u TMUX -u TMUX_PANE
check "outside tmux: nothing recorded"   '[[ ! -e "$PENDING" ]]'

hit TMUX=/tmp/sock,1,0 TMUX_PANE=%3
check "in tmux: the session is recorded" '[[ $(jq -r .pane "$PENDING") == %3 && $(jq -r .pane_pid "$PENDING") == "$PANE_A" ]]'
check "after the reset and a grace"      '(( $(jq .due "$PENDING") >= $(date +%s) + 170 ))'
check "a resume job is queued"           'grep -lq "resume claude" "$QUEUE"/*'
check "status counts it"                 '[[ $(cp_run status) == *"Resume        : 1 session"* ]]'

cp_run resume claude
check "before it is due: leaves it"      '[[ -z $(keys) && -e "$PENDING" ]]'

due_now
cp_run resume claude
check "due and still stopped: types continue" '[[ $(keys) == "continue Enter " ]]'
check "and counts the attempt"           '[[ $(jq .attempts "$PENDING") == 1 ]]'

hit TMUX=/tmp/sock,1,0 TMUX_PANE=%3
check "hitting the limit again keeps the count" '[[ $(jq .attempts "$PENDING") == 1 ]]'

echo '{"type":"user","message":{"content":"continue"}}' >> "$T"
due_now
cp_run resume claude
check "continued: forgotten, nothing typed" '[[ $(keys) == "continue Enter " && ! -e "$PENDING" ]]'

echo '{"type":"assistant","error":"rate_limit"}' >> "$T"
hit TMUX=/tmp/sock,1,0 TMUX_PANE=%3
echo '{"type":"system","subtype":"informational","content":"Automatic continue cancelled · /rate-limit-options to re-arm"}' >> "$T"
due_now
cp_run resume claude
check "cancelled with Esc: left alone"   '[[ $(keys) == "continue Enter " && ! -e "$PENDING" ]]'

echo '{"type":"assistant","error":"rate_limit"}' >> "$T"
hit TMUX=/tmp/sock,1,0 TMUX_PANE=%3
echo "$PANE_B" > "$CP_TEST/tmux-pane-pid"
due_now
cp_run resume claude
check "pane runs something else: not typed into" '[[ $(keys) == "continue Enter " && ! -e "$PENDING" ]]'

echo "$PANE_A" > "$CP_TEST/tmux-pane-pid"
hit TMUX=/tmp/sock,1,0 TMUX_PANE=%3
jq '.due = 0 | .attempts = 2' "$PENDING" > "$PENDING.t" && mv "$PENDING.t" "$PENDING"
cp_run resume claude
check "two tries: gives up and says so"  '[[ $(keys) == "continue Enter " && ! -e "$PENDING" && $(count resume-failed notify-delivered) == 1 ]]'

kill "$PANE_A" "$PANE_B" 2>/dev/null
install_cp uninstall >/dev/null
check "uninstall takes the hook out"     '! grep -qF "$MARKER" "$S" && [[ $(our_jobs) == 0 ]]'

# ======================================================================
section "the Claude Code plugin brings the hook and installs the rest"

v="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$INSTALLER")"
check "one version everywhere" '[[ -n $v && $(jq -r .version "$ROOT/package.json") == "$v" && $(jq -r .version "$ROOT/.claude-plugin/plugin.json") == "$v" && $(jq -r ".metadata.version, .plugins[0].version" "$ROOT/.claude-plugin/marketplace.json" | sort -u) == "$v" ]]'
check "marketplace names the plugin" '[[ $(jq -r .plugins[0].name "$ROOT/.claude-plugin/marketplace.json") == $(jq -r .name "$ROOT/.claude-plugin/plugin.json") ]]'

HOOK="$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
new_home plugin
with_cs
echo '{"type":"assistant","error":"rate_limit"}' > "$H/t.jsonl"
plugin_hook() {
    printf '{"session_id":"p1","transcript_path":"%s"}' "$H/t.jsonl" |
        in_home env CLAUDE_PLUGIN_ROOT="$ROOT" TMUX=/tmp/sock,1,0 TMUX_PANE=%7 bash -c "$HOOK"
}
plugin_hook; rc=$?
check "hook before install: quiet no-op" '[[ $rc == 0 && ! -e "$BASE" ]]'

check "status before install says so" '[[ $(in_home "$ROOT/scripts/entry.sh" status) == *"/fluid:install"* ]]'
in_home "$ROOT/scripts/entry.sh" install >/dev/null
check "plugin install: status line wrapped" '[[ $(jq -r .statusLine.command "$S") == "$CP statusline claude" ]]'
check "plugin install: no hook in settings" '! jq -e .hooks.StopFailure "$S" >/dev/null'

echo "$$" > "$CP_TEST/tmux-pane-pid"
plugin_hook
in_home "$ROOT/scripts/entry.sh" anchor '07:00;touch x' >/dev/null; rc=$?
check "anchor refuses anything but HH:MM|off" '[[ $rc == 2 && ! -e "$BASE/anchor" ]]'
in_home "$ROOT/scripts/entry.sh" anchor 07:30 >/dev/null
check "anchor takes a time"              '[[ $(cat "$BASE/anchor") == 07:30 ]]'
check "the plugin hook records the session" '[[ $(jq -r .pane "$BASE/state/claude/pending/p1.json") == %7 ]]'
install_cp uninstall >/dev/null

# ======================================================================
echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
