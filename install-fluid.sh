#!/usr/bin/env bash
# Fluid - enhancements for Claude Code
# Copyright (C) 2026 Jason Zhou
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version. See the LICENSE file for details.
set -euo pipefail

BASE="$HOME/.fluid"
STATE="$BASE/state"
BIN="$BASE/fluid.sh"
PROVIDERS="$BASE/providers"
NOTIFY="$BASE/notify.sh"
ANCHOR="$BASE/anchor"
MARKER="/.fluid/fluid.sh"

# Agents that run a status line command of our choosing, and where each keeps
# its settings. Wrapping one means editing that file, so only agents actually
# installed here are ever touched.
agent_settings() {
    case "$1" in
        claude) printf '%s\n' "$HOME/.claude/settings.json" ;;
        agy)    printf '%s\n' "$HOME/.gemini/antigravity-cli/settings.json" ;;
        *)      return 1 ;;
    esac
}

# 状態栏を包むことのあるエージェントすべて。取り除くときはこちらを使う:
# エージェント本体が PATH から見えなくなっても、設定に残した痕跡は消せるように。
# Claude Code is still listed so that what versions before 0.3.0 wrote into
# its settings comes out again; it is no longer wrapped (see wrapped_agents).
known_agents() {
    printf '%s\n' claude agy
}

# Agents whose status line gets wrapped. Claude Code's readings come from the
# plugin's hooks module instead, so its settings are never edited.
wrapped_agents() {
    command -v agy >/dev/null 2>&1 && printf '%s\n' agy
    return 0
}

# The command that agent used to run, saved with its own state
agent_orig() {
    printf '%s\n' "$STATE/$1/original-statusline-command"
}

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") [install|uninstall]

  install     Install or upgrade Fluid (the default)
  uninstall   Remove Fluid and leave the rest of settings.json alone
USAGE
}

# timeout is GNU; macOS may have it as gtimeout, or not at all
with_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
    fi
}

require() {
    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Required command not found: $cmd" >&2
            exit 1
        fi
    done
}

# シンボリックリンクをたどった先の実体のパス。dotfiles で管理された設定を
# 書き換えるとき、リンクを普通のファイルで置き換えてしまわないように
resolve_link() {
    local path="$1" link n=0

    while [[ -L "$path" ]] && (( n < 40 )); do
        link="$(readlink "$path")"
        case "$link" in
            /*) path="$link" ;;
            *)  path="$(dirname "$path")/$link" ;;
        esac
        n=$((n + 1))
    done
    printf '%s\n' "$path"
}

# 設定ファイル $1 を jq（残りの引数、最後がフィルタ）で書き換える。一時ファイルは
# 実体と同じディレクトリに元の権限のまま作り、検証してから mv で置き換えるので、
# 途中で失敗しても元のファイルは壊れない。中身が変わらなければ何もしない
edit_json() {
    local file target tmp
    file="$1"
    shift

    target="$(resolve_link "$file")"
    tmp="$(mktemp "$(dirname "$target")/.fluid-settings.XXXXXX")" || return 1
    cp -p "$target" "$tmp" || { rm -f "$tmp"; return 1; }

    if ! jq "$@" "$target" > "$tmp" || ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "Could not update $file; it was left as it was." >&2
        return 1
    fi

    if cmp -s <(jq -S . "$target") <(jq -S . "$tmp"); then
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$target"
}

# 設定のバックアップは新しいものから $2 個だけ残す。名前の末尾の時刻で並べる
# （cp -p で取るので、更新時刻は元のファイルのものになっている）
prune_backups() {
    local file="$1" keep="$2" f

    for f in "$file".fluid-*-backup.*; do
        [[ -e "$f" ]] || continue
        printf '%s\t%s\n' "${f##*.}" "$f"
    done | sort -r | tail -n +"$((keep + 1))" | cut -f2- |
        while IFS= read -r f; do
            rm -f "$f"
        done
}

# The one definition of "what Fluid added to settings.json", used by
# both upgrade and uninstall so the two can never disagree.
#
# It works on the current file rather than restoring a backup, because the
# user and other tools may have changed settings.json since we installed.
# The statusLine wrapper turns back into the user's own command (or goes away
# if there was none), hooks that run our script are dropped, and a hook group
# or event is only removed when taking ours out left it empty. Everything
# else passes through untouched.
STRIP_FILTER='
def ours: type == "string" and contains($marker);

def has_ours_group:
    type == "object" and (.hooks | type) == "array" and any(.hooks[]; .command | ours);

def has_ours_event:
    type == "array" and any(.[]; has_ours_group);

if (.statusLine | type) == "object" and (.statusLine.command | ours) then
    # Never restore a command that is itself our wrapper, or it would call itself
    if $orig != "" and ($orig | ours | not) then
        .statusLine.command = $orig
    else
        del(.statusLine)
    end
else
    .
end
|
if (.hooks | type) == "object" and any(.hooks[]; has_ours_event) then
    .hooks |= with_entries(
        if (.value | has_ours_event) then
            .value |= map(
                if has_ours_group then
                    .hooks |= map(select((.command | ours) | not))
                    | if (.hooks | length) == 0 then empty else . end
                else
                    .
                end
            )
            | if (.value | length) == 0 then empty else . end
        else
            .
        end
    )
    | if (.hooks | length) == 0 then del(.hooks) else . end
else
    .
end
'

is_installed() {
    [[ -e "$BASE" ]] && return 0

    local id file
    for id in $(known_agents); do
        file="$(agent_settings "$id")" || continue
        [[ -f "$file" ]] || continue
        jq -e --arg marker "$MARKER" --arg orig "" ". as \$in | ($STRIP_FILTER) != \$in" "$file" >/dev/null 2>&1 &&
            return 0
    done

    return 1
}

status_command() {
    [[ -f "$1" ]] || return 0
    jq -r 'if (.statusLine | type) == "object" then .statusLine.command // empty else empty end' "$1" 2>/dev/null || true
}

# What uninstall leaves at our script's path when another program still calls
# it: a stand-in that only renders the status line we used to wrap.
write_passthrough() {
    local dest="$1" tmp

    tmp="$(mktemp "$BASE/.passthrough.XXXXXX")"

    {
        echo '#!/usr/bin/env bash'
        echo '# Fluid was uninstalled, but another program had wrapped the status'
        echo '# line around it and still calls this path. This pass-through keeps that'
        echo '# chain working by rendering the command Fluid used to wrap. Run the'
        echo '# uninstaller again once nothing calls it, and it goes away for good.'

        # Same loop guard as the real script
        echo '[[ -z "${FLUID_IN_STATUSLINE:-}" ]] || exit 0'
        echo 'export FLUID_IN_STATUSLINE=1'
        # The caller names the agent, so the right command is rendered
        printf 'state=%q\n' "$STATE"
        echo 'if [[ "${1:-}" == statusline ]]; then'
        echo '    orig="$state/${2:-claude}/original-statusline-command"'
        echo '    [[ -s "$orig" ]] && exec bash -c "$(cat "$orig")"'
        echo 'fi'
    } > "$tmp"

    chmod +x "$tmp"

    # Rename over the old file so a copy that is running right now keeps its inode
    mv "$tmp" "$dest"
}

PROBE_INPUT='{"hook_event_name":"Status","session_id":"fluid-probe","transcript_path":"/dev/null","cwd":"/tmp","model":{"id":"claude","display_name":"Claude"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"version":"0","output_style":{"name":"default"}}'

# Does this status line command end up running our script?
#
# settings.json alone cannot tell "another program wrapped us" from "another
# program replaced us", and guessing wrong is costly both ways: remove our
# script from under a wrapper and its status line breaks; wrap a wrapper that
# calls us and the two call each other on every refresh. So ask directly:
# swap our script for a probe, run the command once, and swap it back.
#
# Hooks and scheduled runs keep calling our script while the probe is in
# place. So the probe counts only a statusline call as a hit, and hands every
# call, that one included, on to the real script: nothing is swallowed, and a
# hook firing meanwhile cannot pass for a wrapper. The real script goes back
# however this ends, including HUP (an SSH session dropping mid-install) and
# TERM, which would otherwise leave the probe in place for good.
PROBE_DIR=""
PROBE_SAVED=""

restore_probed_bin() {
    if [[ -n "$PROBE_SAVED" && -f "$PROBE_SAVED" ]]; then
        mv -f "$PROBE_SAVED" "$BIN"
    fi

    if [[ -n "$PROBE_DIR" ]]; then
        rm -rf "$PROBE_DIR"
    fi

    # A probe interrupted before it was renamed into place
    rm -f "$BASE"/.probe.*

    PROBE_SAVED=""
    PROBE_DIR=""
}

write_probe() {
    local tmp
    # $1: 調べているエージェント

    tmp="$(mktemp "$BASE/.probe.XXXXXX")"

    {
        echo '#!/usr/bin/env bash'
        echo '# Temporary: Fluid is checking whether another status line program'
        echo '# calls it. See chain_calls_us() in the installer.'
        # 調べているエージェントの状態栏からの呼び出しだけを数える。同じ時に
        # 別のエージェントの状態栏が更新されても、包まれている証拠にはならない
        printf 'if [[ "${1:-}" == statusline && "${2:-claude}" == %q ]]; then\n' "$1"
        printf '    : > %q\n' "$PROBE_DIR/called"
        echo 'fi'
        # The real script may be moved back while this starts; then use it there
        echo 'shopt -s execfail'
        printf 'exec %q "$@"\n' "$PROBE_SAVED"
        printf 'exec %q "$@"\n' "$BIN"
    } > "$tmp"

    chmod +x "$tmp"
    mv "$tmp" "$BIN"
}

# 状態栏コマンドを一度だけ実行する。専用のプロセスグループで動かし、終われば
# （10 秒で打ち切っても）グループごと止めるので、孫プロセスも後に残らない
run_probe() {
    local cmd="$1" input="$2"

    (
        set -m
        bash -c "$cmd" < "$input" >/dev/null 2>&1 &
        pid=$!
        i=0
        while (( i < 100 )) && kill -0 "$pid" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
        done
        kill -TERM -- "-$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    ) >/dev/null 2>&1
    return 0
}

# Does agent $2's status line command $1 end up running our script?
chain_calls_us() {
    local cmd="$1" id="$2" rc=1 saved_traps

    [[ -n "$cmd" && "$cmd" != *"$MARKER"* && -f "$BIN" ]] || return 1

    # Traps first, so nothing below can be left behind. Nothing else in the
    # installer sets these today; whatever is set comes back afterwards.
    saved_traps="$(trap -p EXIT HUP INT TERM)"
    trap restore_probed_bin EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    PROBE_DIR="$(mktemp -d)"
    PROBE_SAVED="$(mktemp "$BASE/.saved.XXXXXX")"
    cp -p "$BIN" "$PROBE_SAVED"

    write_probe "$id"
    printf '%s' "$PROBE_INPUT" > "$PROBE_DIR/input"
    run_probe "$cmd" "$PROBE_DIR/input"

    if [[ -e "$PROBE_DIR/called" ]]; then
        rc=0
    fi

    restore_probed_bin
    trap - EXIT HUP INT TERM
    eval "$saved_traps"

    return "$rc"
}

# ロック $1 を誰かが持っているか。flock があればそれで、なければ fluid.sh の
# mkdir のロック（$1.d に持ち主の pid）で確かめる
lock_busy() {
    local holder

    if command -v flock >/dev/null 2>&1; then
        [[ -e "$1" ]] || return 1
        ! flock -n "$1" true 2>/dev/null
    else
        holder="$(cat "$1.d/pid" 2>/dev/null)"
        [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null
    fi
}

# 走っている warmup と resume が終わるのを、最長 $1 秒待つ
wait_for_runs() {
    local deadline dir lock said=""
    deadline=$(( $(date +%s) + $1 ))

    for dir in "$STATE"/*/; do
        [[ -d "$dir" ]] || continue
        for lock in "${dir}warmup.lock" "${dir}resume.lock"; do
            lock_busy "$lock" || continue
            if [[ -z "$said" ]]; then
                echo "Waiting for a run in progress to finish..."
                said=1
            fi
            while lock_busy "$lock" && (( $(date +%s) < deadline )); do
                sleep 0.2
            done
        done
    done
}

# Fluid の予約をすべて取り消す: Linux の at ジョブと、macOS の launchd エージェント
remove_jobs() {
    if command -v atq >/dev/null 2>&1; then
        local job_id rest me
        me="$(id -un)"

        while read -r job_id rest; do
            [[ -n "$job_id" ]] || continue
            # root の atq には全ユーザーのジョブが並ぶ。最後の列が持ち主で、
            # 他のユーザーの Fluid のジョブには触れない
            [[ "${rest##*[[:space:]]}" == "$me" ]] || continue

            # Read the job from a file descriptor, not a pipe: grep -q quitting
            # early would SIGPIPE `at` and pipefail would call the match a miss
            if grep -Fq "$MARKER" < <(at -c "$job_id" 2>/dev/null); then
                atrm "$job_id" >/dev/null 2>&1 || true
            fi
        done < <(atq 2>/dev/null || true)
    fi

    # The one-shot launchd agents queued on macOS
    local plist
    for plist in "$HOME/Library/LaunchAgents/io.github.mrjasonzhou.fluid."*.plist; do
        [[ -e "$plist" ]] || continue
        launchctl remove "$(basename "$plist" .plist)" >/dev/null 2>&1 || true
        rm -f "$plist"
    done
}

# Take Fluid off this machine: our entries in the current settings.json,
# our at jobs, and our directory. Each step touches only what is ours and does
# nothing when that part is already gone, so this is safe to run again, and
# safe to run on an installation that is only half there.
#
# Settings and at jobs are always cleared. Files are where upgrade and
# uninstall part ways: names passed as arguments survive inside
# ~/.fluid, and with none the whole directory goes. Uninstall
# keeps nothing (or only what a pass-through needs); upgrade keeps the runtime
# state and the user's notifier, then schedules the next run again itself.
remove_installation() {
    local keep=("$@")

    local id file orig

    for id in $(known_agents); do
        file="$(agent_settings "$id")" || continue
        [[ -f "$file" ]] || continue

        # 壊れた JSON は編集しない。こちらの痕跡が見えるときだけ知らせる
        if ! jq empty "$file" 2>/dev/null; then
            grep -qF "$MARKER" "$file" &&
                echo "$file is not valid JSON, so Fluid's entries in it were left in place." >&2
            continue
        fi

        orig=""
        [[ -s "$(agent_orig "$id")" ]] && orig="$(cat "$(agent_orig "$id")")"

        # Rewrite only when there was something of ours to take out
        edit_json "$file" --arg marker "$MARKER" --arg orig "$orig" "$STRIP_FILTER"
    done

    remove_jobs

    # 予約はもう取り消したので、新しい実行は始まらない。すでに走っている
    # warmup や resume が終わってから消す。先に消すと、終わった実行が
    # ~/.fluid を作り直し、消えたスクリプトを指す予約を残してしまう
    wait_for_runs 200

    # 待っている間に終わった実行が、次の予約を入れているかもしれない
    remove_jobs

    if (( ${#keep[@]} == 0 )); then
        rm -rf "$BASE"
    elif [[ -d "$BASE" ]]; then
        local name spare=()

        for name in "${keep[@]}"; do
            spare+=(! -name "$name")
        done

        find "$BASE" -mindepth 1 -maxdepth 1 "${spare[@]}" -exec rm -rf {} +
    fi
}

ACTION="${1:-install}"

case "$ACTION" in
    install|uninstall)
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

require jq

# Refuse to touch settings that are not valid JSON: those of an installed agent,
# and any that hold an entry of ours
for _id in $(known_agents); do
    _file="$(agent_settings "$_id")" || continue
    [[ -f "$_file" ]] || continue
    command -v "$_id" >/dev/null 2>&1 || grep -qF "$MARKER" "$_file" || continue
    if ! jq empty "$_file" 2>/dev/null; then
        echo "$_file is not valid JSON. Fix it first; Fluid will not edit it." >&2
        exit 1
    fi
done
unset _id _file

# Agents whose status line another program has wrapped around ours: we stay
# inside those chains rather than wrapping the wrapper. Filled in below.
CHAINED=""

in_chain() {
    [[ " $CHAINED " == *" $1 "* ]]
}

# Probe each agent's current status line, and back its settings up
survey_agents() {
    local suffix="$1" id file cmd
    BACKUPS=""

    for id in $(known_agents); do
        file="$(agent_settings "$id")" || continue
        [[ -f "$file" ]] || continue

        cmd="$(status_command "$file")"
        if chain_calls_us "$cmd" "$id"; then
            CHAINED="$CHAINED $id"
            CHAIN_COMMANDS="$CHAIN_COMMANDS$id: $cmd"$'\n'
        fi

        cp -p "$file" "$file.fluid-$suffix-backup.$STAMP"
        BACKUPS="$BACKUPS$file.fluid-$suffix-backup.$STAMP"$'\n'
        prune_backups "$file" 5
    done
}

CHAIN_COMMANDS=""
BACKUPS=""

STAMP="$(date +%Y%m%d-%H%M%S)"

if [[ "$ACTION" == "uninstall" ]]; then
    if ! is_installed; then
        # Sweep anyway: an interrupted removal can leave an at job behind
        remove_installation
        echo "Fluid is not installed; nothing to remove."
        exit 0
    fi

    survey_agents uninstall

    # The commands any surviving chain has to keep rendering
    SAVED=""
    for _id in $CHAINED; do
        [[ -s "$(agent_orig "$_id")" ]] &&
            SAVED="$SAVED$_id"$'\t'"$(cat "$(agent_orig "$_id")")"$'\n'
    done

    remove_installation

    if [[ -n "$CHAINED" ]]; then
        while IFS=$'\t' read -r _id _cmd; do
            [[ -n "$_id" ]] || continue
            mkdir -p "$(dirname "$(agent_orig "$_id")")"
            printf '%s\n' "$_cmd" > "$(agent_orig "$_id")"
        done <<< "$SAVED"

        write_passthrough "$BIN"
    fi

    echo "Fluid uninstalled."
    if [[ -n "$BACKUPS" ]]; then
        echo "Settings were edited in place. Their state just before:"
        printf '%s' "$BACKUPS" | sed 's/^/  /'
    fi

    if [[ -n "$CHAINED" ]]; then
        echo
        echo "A status line belonging to another program still calls Fluid:"
        printf '%s' "$CHAIN_COMMANDS" | sed 's/^/  /'
        echo "A pass-through was left at $BIN so it keeps working."
        echo "Once that program stops calling it, run uninstall again to remove it."
    fi
    exit 0
fi

# Linux (WSL included) and macOS. Say so plainly rather than stopping on the
# first missing command.
case "$(uname -s)" in
    Linux)
        require at atq atrm
        ;;
    Darwin)
        require launchctl
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Fluid does not run on Windows itself. Run Claude Code inside WSL, with systemd enabled so atd can start, and install Fluid there." >&2
        exit 1
        ;;
    *)
        echo "Fluid supports Linux (and WSL) and macOS; this is $(uname -s)." >&2
        exit 1
        ;;
esac

if [[ -z "$(wrapped_agents)" ]] && ! command -v codex >/dev/null 2>&1 &&
   ! command -v claude >/dev/null 2>&1; then
    echo "None of the agents Fluid knows about are installed here." >&2
    echo "Looked for: claude, codex, agy" >&2
    exit 1
fi

survey_agents install

# 新しいスクリプトはまず一時ディレクトリに書いて検証する。ここで失敗しても、
# 古いインストールにはまだ何も手を付けていない
STAGE="$(mktemp -d)"
REMOVED=""
INSTALL_DONE=""

# 古いインストールを取り除いた後で止まると、予約が消えたままになる。そのとき
# は置けたスクリプトで次の実行を予約し直し、どうなったかを伝える
on_install_exit() {
    rm -rf "$STAGE"
    [[ -n "$REMOVED" && -z "$INSTALL_DONE" ]] || return 0

    echo "Installation did not finish." >&2
    if [[ -x "$BIN" ]] && "$BIN" reschedule >/dev/null 2>&1; then
        echo "The next runs were scheduled again; run the installer again to finish." >&2
    else
        echo "Nothing is scheduled until the installer is run again." >&2
    fi
}
trap on_install_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGE/providers"

cat > "$STAGE/fluid.sh" <<'FLUID_SCRIPT'
#!/usr/bin/env bash
# Fluid - enhancements for coding agents
# Copyright (C) 2026 Jason Zhou
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version. See the LICENSE file for details.
set -u

VERSION="0.3.0"

BASE="$HOME/.fluid"
STATE="$BASE/state"
PROVIDERS="$BASE/providers"
NOTIFY="$BASE/notify.sh"
ANCHOR="$BASE/anchor"
LOG="$BASE/fluid.log"
SELF="$BASE/fluid.sh"

DEFAULT_WINDOW=18000
STALL_GRACE=300
mkdir -p "$STATE"

# アンインストールは state/ ごと消す。その後も走り続けていた実行が、
# ~/.fluid を作り直したり、消えたスクリプトを予約したりしないように、
# 書き込む前にこれで確かめる
installed() {
    [[ -d "$STATE" ]]
}

log() {
    [[ -d "$BASE" ]] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

# ----------------------------------------------------------------- providers
#
# One file per agent under providers/, each defining functions prefixed with
# its id. See docs/PROVIDERS.md for the contract. Nothing below this section
# knows which agents exist.

for _p in "$PROVIDERS"/*.sh; do
    [[ -e "$_p" ]] && source "$_p"
done
unset _p

provider_ids() {
    local f
    shopt -s nullglob
    for f in "$PROVIDERS"/*.sh; do
        basename "$f" .sh
    done
    shopt -u nullglob
}

provider_defines() {
    declare -F "$1_$2" >/dev/null 2>&1
}

# Call a provider function, falling back to the default where there is one
provider_call() {
    local id="$1" fn="$2"
    shift 2

    if provider_defines "$id" "$fn"; then
        "${id}_${fn}" "$@"
    else
        "default_$fn" "$@"
    fi
}

default_label() {
    printf '%s\n' "unknown"
}

default_capabilities() {
    printf 'alert\n'
}

# Most agents word an expired login much the same way
default_auth_failed() {
    grep -Eqi 'login expired|please run /login|log ?in again|authentication_failed|not logged in|unauthorized|oauth[^[:alnum:]]+.*expired'
}

default_warmup() {
    return 1
}

# The cheapest model worth warming up with, if the agent takes one at all.
# Empty means whatever the agent would pick for itself.
default_cheap_model() {
    printf '\n'
}

# Does this output say the model id is not one the agent knows? Models come
# and go; an agent that has dropped one says so plainly.
default_unknown_model() {
    grep -Eqi 'unrecognized_model|unknown model|model.*(does not exist|may not exist|not found|described by this version)'
}


default_parse_limits() {
    cat >/dev/null
    printf '{}\n'
}

provider_can() {
    provider_call "$1" capabilities 2>/dev/null | tr ' ' '\n' | grep -qx "$2"
}

# Providers the core should act on: installed here, and known to us
active_providers() {
    local id
    for id in $(provider_ids); do
        provider_defines "$id" available || continue
        "${id}_available" 2>/dev/null && printf '%s\n' "$id"
    done
}

pstate() {
    printf '%s\n' "$STATE/$1"
}

pget() {
    cat "$STATE/$1/$2" 2>/dev/null || true
}

pset() {
    installed || return 0
    mkdir -p "$STATE/$1"
    printf '%s\n' "$3" > "$STATE/$1/$2"
}

# The model this provider warms up with. Unset means its own choice; "-"
# means the agent's default, which is where a fallback lands.
warmup_model() {
    local stored
    stored="$(pget "$1" warmup_model)"

    if [[ -z "$stored" ]]; then
        provider_call "$1" cheap_model
    elif [[ "$stored" == "-" ]]; then
        printf '\n'
    else
        printf '%s\n' "$stored"
    fi
}

# How long a short window lasts for this provider, as last observed
window_seconds() {
    local w
    w="$(pget "$1" window_seconds)"
    [[ "$w" =~ ^[0-9]+$ ]] && printf '%s\n' "$w" || printf '%s\n' "$DEFAULT_WINDOW"
}

# ------------------------------------------------------------------- notify

# Hand the event to whatever notifier the user installed. Succeeds only when
# the message actually went out: no notifier configured counts as not sent,
# so the event is still delivered once one is set up. A broken or slow
# notifier only fails this call; it never takes the run down with it.
notify() {
    [[ -x "$NOTIFY" ]] || return 1

    if CP_EVENT="$1" CP_MESSAGE="$2" CP_HOST="$(uname -n)" \
        with_timeout 20 "$NOTIFY" >/dev/null 2>&1; then
        return 0
    fi

    log "Notify script failed event=$1"
    return 1
}

# Notify once per stay in a state, where once means delivered once. The flag
# is written only after a successful send, so a send that failed is tried
# again on the next retry rather than counted as done. $1 is the directory
# holding the flag, so providers keep their own.
notify_once() {
    local flag="$1/notified-$2"

    [[ -e "$flag" ]] && return 0
    installed || return 0
    mkdir -p "$1"

    if notify "$3" "$4"; then
        : > "$flag"
    fi
    return 0
}

# Announce a recovery only to those who heard about the problem: $2 is the
# message, the rest are the keys it clears. Their flags stay until the
# announcement is delivered, so it is retried too.
notify_recovered() {
    local dir="$1" message="$2" key flags=()
    shift 2

    for key in "$@"; do
        if [[ -e "$dir/notified-$key" ]]; then
            flags+=("$dir/notified-$key")
        fi
    done

    (( ${#flags[@]} )) || return 0

    if notify "recovered" "$message"; then
        rm -f "${flags[@]}"
    fi
    return 0
}

# ------------------------------------------------------------- portability
#
# Linux and macOS differ in the small tools: GNU date reads `-d @epoch`, BSD
# date wants `-r epoch` and `-j -f` to parse; macOS has no flock, timeout, tac
# or /proc, and its bash is 3.2. Everything below this section goes through
# these helpers instead.

if date -d @0 +%s >/dev/null 2>&1; then
    GNU_DATE=1
else
    GNU_DATE=0
fi

# Format epoch second $1 with date format $2
fmt_time() {
    if (( GNU_DATE )); then
        date -d "@$1" "$2"
    else
        date -r "$1" "$2"
    fi
}

# The epoch second of a local "YYYY-MM-DD HH:MM". BSD date fills any field
# the format leaves out from the current time, so the seconds are spelled out.
parse_time() {
    if (( GNU_DATE )); then
        date -d "$1" +%s
    else
        date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s
    fi
}

with_timeout() {
    local secs="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
    fi
}

# Lines of file $1, last first: tac on Linux, tail -r on macOS
reverse_lines() {
    if command -v tac >/dev/null 2>&1; then
        tac "$1"
    elif tail -r /dev/null >/dev/null 2>&1; then
        tail -r "$1"
    else
        awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' "$1"
    fi
}

HELD_LOCKS=()

# このプロセス自身の pid。サブシェルでは $$ が親の pid のままなので、
# bash 4 以降は BASHPID を使い、bash 3.2 では sh の親 pid から得る
self_pid() {
    if [[ -n "${BASHPID:-}" ]]; then
        printf '%s\n' "$BASHPID"
    else
        sh -c 'echo "$PPID"'
    fi
}

# Take the lock at $2 on file descriptor $1; with $3 = try, give up at once
# instead of waiting. Held until release_lock, or until the process exits.
take_lock() {
    local fd="$1" path="$2" mode="${3:-wait}"

    if command -v flock >/dev/null 2>&1; then
        eval "exec $fd>\"\$path\""
        if [[ "$mode" == try ]]; then
            flock -n "$fd"
        else
            flock "$fd"
        fi
        return
    fi

    # ponytail: a directory as the lock, for systems without flock. A holder
    # that died is spotted by its pid; contention here is a handful of runs.
    local dir="$path.d" holder held
    # Already ours: flock lets a process take its own lock again, so must this.
    # pid ではなく保持リストで判定する（サブシェルは親と同じ $$ を持つため）
    for held in ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}; do
        [[ "$held" == "$dir" ]] && return 0
    done

    while ! mkdir "$dir" 2>/dev/null; do
        holder="$(cat "$dir/pid" 2>/dev/null)"
        if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$dir"
            continue
        fi
        [[ "$mode" == try ]] && return 1
        sleep 0.2
    done

    # 親が先に終了しても、バックグラウンドの保持者が生きている間はロックが残るように
    self_pid > "$dir/pid"
    HELD_LOCKS+=("$dir")
    trap 'rm -rf ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}' EXIT
}

# take_lock で取ったロックを、プロセスの終了を待たずに手放す
release_lock() {
    local fd="$1" dir="$2.d" held kept=()

    if command -v flock >/dev/null 2>&1; then
        eval "exec $fd>&-"
        return 0
    fi

    for held in ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}; do
        [[ "$held" == "$dir" ]] || kept+=("$held")
    done
    HELD_LOCKS=(${kept[@]+"${kept[@]}"})
    rm -rf "$dir"
}

# バックグラウンドの子を起こす前に呼ぶ: 親が持つロックを子に引き継がせない。
# flock の fd が子に残ると、子が終わるまで他のプロセスがロックを待たされ、
# mkdir ロックの一覧が残ると、子の EXIT trap が他人のロックを消してしまう
drop_inherited_locks() {
    exec 5>&- 6>&- 7>&- 8>&- 9>&-
    HELD_LOCKS=()
    trap - EXIT
}

# --------------------------------------------------------------- scheduling
#
# Runs are queued with `at` on Linux and as one-shot launchd agents on macOS.
# FLUID_SCHEDULER overrides the choice, which is how the tests reach both.

if [[ -n "${FLUID_SCHEDULER:-}" ]]; then
    SCHEDULER="$FLUID_SCHEDULER"
elif [[ "$(uname -s)" == Darwin ]]; then
    SCHEDULER=launchd
else
    SCHEDULER=at
fi

LAUNCH_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PREFIX="io.github.mrjasonzhou.fluid"

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Queue `fluid.sh $2 $3` for epoch second $1; prints the job id
submit_job() {
    local target="$1" sub="$2" id="$3"

    if [[ "$SCHEDULER" == at ]]; then
        local output
        # at はジョブに提出時の作業ディレクトリと環境を記録し、実行時にまず
        # そのディレクトリへ cd して、失敗すれば何も実行せずに終わる。提出元は
        # たいてい状態栏を描くセッションで、その作業ディレクトリ（後で消える
        # worktree など）に依存させないよう / から提出し、セッション固有の
        # 変数も持ち込まない
        output="$(
            cd / || exit 1
            unset TMUX TMUX_PANE FLUID_IN_STATUSLINE FLUID_MOD CLAUDECODE \
                CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT
            printf '%q %q %q\n' "$SELF" "$sub" "$id" |
                LC_ALL=C at -t "$(fmt_time "$target" '+%Y%m%d%H%M.%S')" 2>&1
        )" || {
            log "[$id] at refused the job: $output"
            return 1
        }
        awk '/^job [0-9]+ / {print $2; exit}' <<< "$output"
        return
    fi

    # launchd fires on whole minutes; round up so a run is never early
    (( target % 60 == 0 )) || target=$(( (target / 60 + 1) * 60 ))

    # launchd のエージェントは PATH が /usr/bin:/bin:/usr/sbin:/sbin だけで始まり、
    # Homebrew の jq や tmux、~/.local/bin の claude などが見つからない。提出元の
    # PATH を plist に書いておけば、ジョブから提出されるジョブにも引き継がれる
    local job="$target-$$-$RANDOM" label plist month day hour minute arg args=""
    label="$LAUNCH_PREFIX.$job"
    plist="$LAUNCH_DIR/$label.plist"
    read -r month day hour minute <<< "$(fmt_time "$target" '+%m %d %H %M')"

    # The job deletes its own plist first, then runs, then unloads itself;
    # StartCalendarInterval has no year, so it must never be left behind.
    # 電源が切れていて時刻を逃した予約は、launchd が拾い直さないまま翌年の
    # 同じ日まで残る。RunAtLoad でログイン時にも起こし、時刻を過ぎていれば
    # 取り戻す。読み込まれた直後など、まだ早ければ何もせずに待つ
    for arg in /bin/bash -c '[ "$(date +%s)" -ge "$6" ] || exit 0; rm -f -- "$1"; "$2" "$3" "$4"; launchctl remove "$5"' \
               fluid-job "$plist" "$SELF" "$sub" "$id" "$label" "$((target - 30))"; do
        args="$args        <string>$(xml_escape "$arg")</string>"$'\n'
    done

    mkdir -p "$LAUNCH_DIR"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$(xml_escape "$PATH")</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
$args    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Month</key><integer>$((10#$month))</integer>
        <key>Day</key><integer>$((10#$day))</integer>
        <key>Hour</key><integer>$((10#$hour))</integer>
        <key>Minute</key><integer>$((10#$minute))</integer>
    </dict>
</dict>
</plist>
PLIST

    if ! launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 &&
       ! launchctl load "$plist" >/dev/null 2>&1; then
        rm -f "$plist"
        log "[$id] launchd refused the job $label"
        return 1
    fi

    printf '%s\n' "$job"
}

job_exists() {
    local job="${1:-}"
    [[ -n "$job" ]] || return 1

    if [[ "$SCHEDULER" == at ]]; then
        atq 2>/dev/null | awk '{print $1}' | grep -qx "$job"
    else
        [[ -f "$LAUNCH_DIR/$LAUNCH_PREFIX.$job.plist" ]]
    fi
}

remove_job() {
    local job="${1:-}"
    job_exists "$job" || return 0

    if [[ "$SCHEDULER" == at ]]; then
        atrm "$job" >/dev/null 2>&1
    else
        launchctl remove "$LAUNCH_PREFIX.$job" >/dev/null 2>&1
        rm -f "$LAUNCH_DIR/$LAUNCH_PREFIX.$job.plist"
    fi
    return 0
}

# Schedule `scheduled <id>` at $2, replacing whatever this provider had
arm_job() {
    local dir rc=0
    installed || return 0
    dir="$(pstate "$1")"
    mkdir -p "$dir"

    # ロックは予約の差し替えの間だけ持つ。プロセスの終了まで持つと、続く
    # warmup や後から起こすバックグラウンドの子の間も状態栏を待たせてしまう
    take_lock 9 "$dir/schedule.lock"
    arm_job_locked "$@" || rc=$?
    release_lock 9 "$dir/schedule.lock"
    return "$rc"
}

arm_job_locked() {
    local id="$1" target="$2" reason="${3:-unknown}"
    local now old_job old_target
    now="$(date +%s)"
    old_job="$(pget "$id" at_job)"
    old_target="$(pget "$id" at_target)"

    # A target in the past would never fire; push it a few seconds out
    if (( target <= now )); then
        target=$((now + 5))
    fi

    # Same target and the job is still queued: nothing to do
    if [[ "$target" == "$old_target" ]] && job_exists "$old_job"; then
        return 0
    fi

    # Drop the job scheduled last time
    remove_job "$old_job"

    local job_id
    job_id="$(submit_job "$target" scheduled "$id")" || return 1

    if [[ -z "$job_id" ]]; then
        log "[$id] Could not determine the job id"
        return 1
    fi

    pset "$id" at_job "$job_id"
    pset "$id" at_target "$target"
    pset "$id" at_reason "$reason"

    log "[$id] Scheduled job=$job_id target=$(fmt_time "$target" '+%Y-%m-%d %H:%M:%S') reason=$reason"
}

# --------------------------------------------------------------- the anchor

# The first time of day $2 (HH:MM) falls at or after the moment $1
anchor_after() {
    local from="$1" anchor="$2" day today

    day="$(fmt_time "$from" '+%Y-%m-%d')" || return 1
    today="$(parse_time "$day $anchor" 2>/dev/null)" || return 1

    if (( today >= from )); then
        printf '%s\n' "$today"
        return 0
    fi

    # Tomorrow's date, then the time: `date -d "<date> <time> + 1 day"` reads
    # the "+ 1" as a UTC offset instead of a day, which silently shifts the hour
    day="$(fmt_time "$((from + 86400))" '+%Y-%m-%d')" || return 1
    parse_time "$day $anchor" 2>/dev/null
}

# Hold a window back so that none ever runs across the anchor time.
#
# A window opened at $2 covers the next $1 seconds. If the anchor falls inside
# that stretch, opening at the anchor itself is no longer possible, so wait for
# it instead: a window due at 03:00 would cover 03:00-08:00 and swallow 06:00,
# so it opens at 06:00. Leaves the target alone when no anchor is set, when the
# window starts exactly on it, or when the anchor is beyond its end.
apply_anchor() {
    local window="$1" target="$2" anchor next

    anchor="$(cat "$ANCHOR" 2>/dev/null || true)"

    if [[ ! "$anchor" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
       ! next="$(anchor_after "$target" "$anchor")" ||
       [[ ! "$next" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$target"
        return 0
    fi

    if (( next > target && next < target + window )); then
        printf '%s\n' "$next"
    else
        printf '%s\n' "$target"
    fi
}

# Schedule the opening of a new window, honouring the anchor
arm_window() {
    local id="$1" target="$2" reason="$3" anchored

    anchored="$(apply_anchor "$(window_seconds "$id")" "$target")"

    if (( anchored != target )); then
        log "[$id] Holding the next window until the anchor at $(fmt_time "$anchored" '+%H:%M')"
        target="$anchored"
        reason="anchor-hold"
    fi

    arm_job "$id" "$target" "$reason"
}

# ------------------------------------------------------------ the scheduler

# Is atd running? 0 yes, 1 no, 2 cannot tell. systemd first, then the process
# itself, for systems without systemd (WSL, containers) or an atd started by hand.
scheduler_running() {
    # launchd is always there; a job it did not run shows up as overdue
    [[ "$SCHEDULER" == launchd ]] && return 0

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet atd 2>/dev/null; then
        return 0
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x atd >/dev/null 2>&1 && return 0
        return 1
    fi

    return 2
}

# A run well past its time and still queued means atd is not running it.
#
# This is called on every status line refresh, which can be every second, so
# the common case must cost nothing: two comparisons, and out. Only when a
# target is overdue and the last look was a while ago does a background check
# run, one at a time, so the status line never waits on atq or a notifier, and
# the log and any notification retry happen at most every STALL_GRACE seconds.
maybe_check_stall() {
    local id="$1" now target last

    target="$(pget "$id" at_target)"
    [[ "$target" =~ ^[0-9]+$ ]] || return 0

    now="$(date +%s)"
    (( now > target + STALL_GRACE )) || return 0

    last="$(cat "$STATE/stall_checked_at" 2>/dev/null || true)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now >= last + STALL_GRACE )) || return 0

    (
        drop_inherited_locks
        take_lock 7 "$STATE/stall.lock" try || exit 0
        check_stall "$id" "$target"
    ) </dev/null >/dev/null 2>&1 &
}

check_stall() {
    local id="$1" target="$2" job last

    # Another refresh may have looked while this one waited for the lock
    last="$(cat "$STATE/stall_checked_at" 2>/dev/null || true)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( $(date +%s) >= last + STALL_GRACE )) || return 0
    date +%s > "$STATE/stall_checked_at"

    job="$(pget "$id" at_job)"
    job_exists "$job" || return 0

    log "[$id] Scheduled run is overdue and still queued: job=$job target=$(fmt_time "$target" '+%Y-%m-%d %H:%M:%S')"
    local hint="Is atd running? Start it with: sudo systemctl enable --now atd"
    [[ "$SCHEDULER" == launchd ]] && hint="launchd did not run it; see ~/.fluid/fluid.log"
    notify_once "$STATE" stalled "scheduler-stalled" \
        "Fluid's run scheduled for $(fmt_time "$target" '+%H:%M') has not happened, so nothing is being kept open. $hint"
}

# ------------------------------------------------------------- observations

# Take one reading from a provider: its own JSON on stdin, normalised through
# the provider, stored, and the next window scheduled from it. $2 names where
# it came from (statusline, mod), for status.
observe() {
    local id="$1" origin="${2:-}" input parsed key value reset

    input="$(cat)"
    parsed="$(printf '%s' "$input" | provider_call "$id" parse_limits 2>/dev/null)" || return 0
    [[ -n "$parsed" ]] || return 0

    # 読み取りが最後にどこから、いつ届いたか。status で見えるように
    if [[ "$parsed" != "{}" ]]; then
        pset "$id" last_reading "$(date +%s)"
        [[ -n "$origin" ]] && pset "$id" reading_source "$origin"
    fi

    for key in window_seconds used_percent resets_at long_used_percent long_resets_at; do
        value="$(
            printf '%s' "$parsed" |
                jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
        )"
        [[ -n "$value" ]] && pset "$id" "$key" "$value"
    done

    reset="$(pget "$id" resets_at)"

    if [[ "$reset" =~ ^[0-9]+$ ]] && provider_can "$id" keep; then
        # Trust the reported reset time, plus 15s of slack
        arm_window "$id" "$((reset + 15))" "official-reset"
    fi

    maybe_check_stall "$id"
}

# For providers that cannot push, fetch a reading on demand
refresh_limits() {
    local id="$1" native

    provider_defines "$id" pull_limits || return 0
    native="$(provider_call "$id" pull_limits 2>/dev/null)" || return 0
    [[ -n "$native" ]] || return 0

    printf '%s' "$native" | observe "$id"
}

# A status line wrapper: feed the payload to observe, then render whatever the
# user had before us. The original command lives with the provider's state.
statusline() {
    local id="$1" input original orig_file

    # Two status line programs that each wrap the other would call each other
    # on every refresh; the inner call stops here instead
    if [[ -n "${FLUID_IN_STATUSLINE:-}" ]]; then
        cat >/dev/null
        return 0
    fi
    export FLUID_IN_STATUSLINE=1

    input="$(cat)"
    # Agents kill a status line still running when the next refresh
    # comes. Killed inside `at`, observe left a half-written job that never
    # runs and is never removed (435 of them on one machine), so it runs on
    # its own and the status line does not wait for it.
    # ponytail: no setsid on macOS; there it only leaves the parent's process
    # group if Claude Code kills the whole group
    if command -v setsid >/dev/null 2>&1; then
        printf '%s' "$input" | setsid "$SELF" observe "$id" statusline >/dev/null 2>&1 &
    else
        printf '%s' "$input" | "$SELF" observe "$id" statusline >/dev/null 2>&1 &
    fi

    orig_file="$(pstate "$id")/original-statusline-command"

    if [[ -s "$orig_file" ]]; then
        original="$(cat "$orig_file")"
        printf '%s' "$input" | bash -c "$original"
        return
    fi

    # Only fall back to a minimal line when nothing is wrapped
    local pct reset
    pct="$(pget "$id" used_percent)"
    reset="$(pget "$id" resets_at)"

    if [[ "$reset" =~ ^[0-9]+$ ]]; then
        printf '%s%% used | resets %s\n' "${pct:-?}" "$(fmt_time "$reset" '+%H:%M')"
    fi
}

# ------------------------------------------------------------------- warmup

# Is the long window (weekly, monthly) full? Then a new short window is no use.
is_long_limited() {
    local id="$1" now reset pct
    now="$(date +%s)"
    reset="$(pget "$id" long_resets_at)"
    pct="$(pget "$id" long_used_percent)"

    [[ "$reset" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$pct" ]] || return 1
    (( reset > now )) || return 1

    awk -v p="$pct" 'BEGIN { exit !(p >= 99.9) }'
}

do_warmup() {
    local id="$1" dir
    installed || return 0
    dir="$(pstate "$id")"
    mkdir -p "$dir"

    # Never let two warmups run at once
    if ! take_lock 8 "$dir/warmup.lock" try; then
        return 0
    fi

    local now
    now="$(date +%s)"

    if is_long_limited "$id"; then
        local long_reset
        long_reset="$(pget "$id" long_resets_at)"
        log "[$id] Long window is full; waiting for it to reset"
        arm_job "$id" "$((long_reset + 15))" "long-window-reset"
        return 0
    fi

    local started output rc model
    started="$(date +%s)"
    model="$(warmup_model "$id")"

    # エージェントが残す子プロセスに warmup のロックを持ち去らせない。
    # 手で実行されても予約で実行されても同じように、/ で動かす（呼び出し元の
    # プロジェクトの AGENTS.md などを読ませない）
    # exec, not `8>&-` on the call: bash 3.2 lets a function's background
    # children keep an fd closed that way
    output="$(exec 8>&-; cd / && provider_call "$id" warmup "$model")"
    rc=$?

    # When the agent no longer knows this model, drop to the one it picks for
    # itself and remember that, rather than failing every window until
    # someone reads the log.
    if (( rc != 0 )) && [[ -n "$model" ]] &&
       printf '%s\n' "$output" | provider_call "$id" unknown_model; then
        log "[$id] Model '$model' is gone; falling back to the agent's own default"
        pset "$id" warmup_model "-"
        notify "model-changed" \
            "$(provider_call "$id" label) no longer knows the model Fluid warmed up with ($model), so it has switched to the agent's default. Pick another with: fluid.sh model $id <name>" || true

        output="$(exec 8>&-; cd / && provider_call "$id" warmup "")"
        rc=$?
    fi

    if (( rc == 0 )); then
        pset "$id" last_success "$started"
        pset "$id" failure_count 0
        rm -f "$dir/auth_required"
        notify_recovered "$dir" "Fluid is back to normal for $(provider_call "$id" label); windows are opening again." auth failing missing

        log "[$id] Warmup succeeded output=$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)"

        # A warmup usually reports nothing about limits, so estimate the next
        # window from this request and let the next reading correct it
        arm_window "$id" "$((started + $(window_seconds "$id") + 15))" "estimated-next-reset"
        return 0
    fi

    if printf '%s\n' "$output" | provider_call "$id" auth_failed; then
        local seen
        seen="$(pget "$id" auth_required)"
        pset "$id" auth_required "${seen:-$now}"
        log "[$id] Authentication required; warmups paused output=$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-300)"

        # A sign-in can come back on its own, so the recheck below has to fail
        # too before this is worth a message. The first one is only logged.
        if [[ -n "$seen" ]]; then
            notify_once "$dir" auth "auth-required" \
                "$(provider_call "$id" label) is no longer authenticated, so Fluid has stopped opening windows for it. Sign in again."
        fi

        # Leave room to recover on its own if the failure was temporary
        arm_job "$id" "$((now + 3600))" "auth-recheck"
        return 1
    fi

    local failures delay
    failures="$(pget "$id" failure_count)"
    [[ "$failures" =~ ^[0-9]+$ ]] || failures=0

    failures=$((failures + 1))
    pset "$id" failure_count "$failures"

    case "$failures" in
        1) delay=60 ;;
        2) delay=120 ;;
        3) delay=300 ;;
        *) delay=600 ;;
    esac

    log "[$id] Warmup failed rc=$rc retry=${delay}s output=$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-300)"

    # Three failures means the backoff has stretched to minutes; worth a word
    if (( failures >= 3 )); then
        notify_once "$dir" failing "warmup-failing" \
            "Fluid has failed $failures warmups in a row for $(provider_call "$id" label), and is retrying every ${delay}s. See ~/.fluid/fluid.log"
    fi

    arm_job "$id" "$((now + delay))" "warmup-retry"
    return 1
}

# ---------------------------------------------------------------- scheduling

# Put back the run an earlier version had planned, after an upgrade removed
# its at job. The target was computed then; one already missed runs now.
reschedule() {
    local id target reason

    for id in $(active_providers); do
        provider_can "$id" keep || continue

        target="$(pget "$id" at_target)"
        reason="$(pget "$id" at_reason)"

        if [[ "$target" =~ ^[0-9]+$ ]]; then
            arm_job "$id" "$target" "${reason:-rescheduled}"
        else
            # Nothing planned yet. A provider we can poll starts right away;
            # one that pushes waits for its first reading.
            refresh_limits "$id"
        fi
    done
}

scheduled() {
    local id="$1"

    # atd ran us, so whatever stall was reported is over
    pset "$id" last_run "$(date +%s)"
    notify_recovered "$STATE" "Fluid's scheduled runs are happening again." stalled

    # エージェントが見つからなければ warmup は失敗し続けるだけなので、
    # 一度だけ知らせて、一時間ごとに戻ってくるか確かめる
    if ! { provider_defines "$id" available && "${id}_available"; } 2>/dev/null; then
        log "[$id] $(provider_call "$id" label) is not installed or not on PATH; looking again in an hour"
        notify_once "$(pstate "$id")" missing "agent-missing" \
            "Fluid cannot find $(provider_call "$id" label) (PATH=$PATH), so it has stopped opening windows for it."
        arm_job "$id" "$(( $(date +%s) + 3600 ))" "agent-missing"
        return 0
    fi

    # A provider that cannot push its limits gets read now, so the decision
    # below and the next estimate start from something current
    refresh_limits "$id"

    do_warmup "$id" || true
}

# ------------------------------------------------------------------- status

show_status() {
    local scheduler anchor id label dir target reason job last_run last_success
    local failures pct reset long_pct overdue window

    scheduler_running
    case $? in
        0) [[ "$SCHEDULER" == launchd ]] && scheduler="launchd" || scheduler="atd running" ;;
        1) scheduler="ATD NOT RUNNING - nothing scheduled will run" ;;
        *) scheduler="unknown" ;;
    esac

    anchor="$(cat "$ANCHOR" 2>/dev/null || true)"

    echo "Version         : $VERSION"
    echo "Scheduler       : $scheduler"
    echo "Anchor          : ${anchor:-not set}"

    if [[ -x "$NOTIFY" ]]; then
        echo "Notify          : $NOTIFY"
    else
        echo "Notify          : not configured"
    fi

    for id in $(active_providers); do
        label="$(provider_call "$id" label)"
        dir="$(pstate "$id")"
        target="$(pget "$id" at_target)"
        reason="$(pget "$id" at_reason)"
        job="$(pget "$id" at_job)"
        last_run="$(pget "$id" last_run)"
        last_success="$(pget "$id" last_success)"
        failures="$(pget "$id" failure_count)"
        pct="$(pget "$id" used_percent)"
        reset="$(pget "$id" resets_at)"
        long_pct="$(pget "$id" long_used_percent)"
        window="$(window_seconds "$id")"
        overdue=""

        echo
        echo "[$id] $label"

        if ! provider_can "$id" keep; then
            echo "  Keep          : not supported by this agent"
        fi

        if [[ "$reset" =~ ^[0-9]+$ ]]; then
            echo "  Window        : ${pct:-?}% used, $((window / 60))min, resets $(fmt_time "$reset" '+%Y-%m-%d %H:%M:%S')"
        else
            echo "  Window        : unknown"
        fi

        [[ -n "$long_pct" ]] && echo "  Long window   : ${long_pct}% used"

        if [[ "$target" =~ ^[0-9]+$ ]]; then
            if (( $(date +%s) > target + STALL_GRACE )) && job_exists "$job"; then
                overdue=" (OVERDUE, still queued)"
            fi
            echo "  Scheduled     : $(fmt_time "$target" '+%Y-%m-%d %H:%M:%S')$overdue"
            echo "  Reason        : ${reason:-none}   at job: ${job:-none}"
        else
            echo "  Scheduled     : none"
        fi

        local last_reading origin
        last_reading="$(pget "$id" last_reading)"
        origin="$(pget "$id" reading_source)"
        case "$origin" in
            mod)        origin="hooks module" ;;
            statusline) origin="status line" ;;
        esac
        if [[ "$last_reading" =~ ^[0-9]+$ ]]; then
            echo "  Readings      : ${origin:-unknown}, last $(fmt_time "$last_reading" '+%Y-%m-%d %H:%M:%S')"
        fi
        echo "  Warmup model  : $(warmup_model "$id" | sed 's/^$/(agent default)/')"
        echo "  Failures      : ${failures:-0}   auth: $([[ -f "$dir/auth_required" ]] && echo 'RELOGIN MAY BE REQUIRED' || echo OK)"

        if [[ "$last_run" =~ ^[0-9]+$ ]]; then
            echo "  Last run      : $(fmt_time "$last_run" '+%Y-%m-%d %H:%M:%S')"
        fi
        if [[ "$last_success" =~ ^[0-9]+$ ]]; then
            echo "  Last warmup   : $(fmt_time "$last_success" '+%Y-%m-%d %H:%M:%S')"
        fi
    done
}

show_providers() {
    local id
    shopt -s nullglob

    for id in $(provider_ids); do
        printf '%-10s %-18s %-12s %s\n' \
            "$id" \
            "$(provider_call "$id" label)" \
            "$(provider_defines "$id" available && { "${id}_available" && echo installed || echo "not found"; })" \
            "$(provider_call "$id" capabilities)"
    done

    shopt -u nullglob
}

# ------------------------------------------------------------------ anchor

# Show, set or clear the time of day windows should open at
set_anchor() {
    local value="${1:-}" id target

    if [[ -z "$value" ]]; then
        if [[ -s "$ANCHOR" ]]; then
            echo "Anchor: $(cat "$ANCHOR")"
        else
            echo "Anchor: not set"
        fi
        return 0
    fi

    if [[ "$value" == off ]]; then
        rm -f "$ANCHOR"
        echo "Anchor cleared; windows open as soon as they can again."
    elif [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        printf '%s\n' "$value" > "$ANCHOR"
        echo "Anchor set to $value; no window will run across it."
    else
        echo "Usage: $0 anchor [HH:MM|off]" >&2
        return 2
    fi

    # Re-plan what is already scheduled under the new setting
    for id in $(active_providers); do
        provider_can "$id" keep || continue
        target="$(pget "$id" at_target)"
        [[ "$target" =~ ^[0-9]+$ ]] || continue
        arm_window "$id" "$target" "$(pget "$id" at_reason || echo rescheduled)"
    done
}

# Show or set the model an agent warms up with
set_warmup_model() {
    local id="${1:-}" value="${2:-}"

    if [[ -z "$id" ]]; then
        for id in $(active_providers); do
            printf '%-10s %s\n' "$id" "$(warmup_model "$id" | sed 's/^$/(agent default)/')"
        done
        return 0
    fi

    if ! provider_defines "$id" available; then
        echo "Unknown agent: $id" >&2
        return 2
    fi

    case "$value" in
        "")      printf '%-10s %s\n' "$id" "$(warmup_model "$id" | sed 's/^$/(agent default)/')" ;;
        auto)    rm -f "$(pstate "$id")/warmup_model"
                 echo "$id warms up with $(warmup_model "$id" | sed 's/^$/the agent default/') again." ;;
        default) pset "$id" warmup_model "-"
                 echo "$id warms up with the agent's own default." ;;
        *)       pset "$id" warmup_model "$value"
                 echo "$id warms up with $value." ;;
    esac
}

notify_test() {
    if [[ ! -x "$NOTIFY" ]]; then
        echo "No executable notify script at $NOTIFY" >&2
        echo "Copy one of $BASE/notify/*.sample there and edit it." >&2
        return 1
    fi

    # Run it in the open so the user sees why it failed
    CP_EVENT="test" \
    CP_MESSAGE="Test notification from Fluid." \
    CP_HOST="$(uname -n)" \
        "$NOTIFY"

    local rc=$?
    echo "Notify script exited with $rc"
    return "$rc"
}

# --------------------------------------------------------------------- main

# Subcommands that act on one provider default to the first active one, so
# that jobs and hooks written by older versions still work.
default_provider() {
    active_providers | head -1
}

case "${1:-}" in
    statusline)
        statusline "${2:-$(default_provider)}"
        ;;
    observe)
        observe "${2:-$(default_provider)}" "${3:-}"
        ;;
    warmup)
        do_warmup "${2:-$(default_provider)}"
        ;;
    scheduled)
        scheduled "${2:-$(default_provider)}"
        ;;
    reschedule)
        reschedule
        ;;
    scheduler-check)
        scheduler_running
        ;;
    status)
        show_status
        ;;
    providers)
        show_providers
        ;;
    anchor)
        set_anchor "${2:-}"
        ;;
    model)
        set_warmup_model "${2:-}" "${3:-}"
        ;;
    notify-test)
        notify_test
        ;;
    # フック・モジュールから: ログに一行、通知を一つ
    log)
        log "[${2:-}] ${3:-}"
        ;;
    notify)
        log "Notify event=${2:-} ${3:-}"
        notify "${2:-}" "${3:-}" || true
        ;;
    version)
        echo "$VERSION"
        ;;
    *)
        echo "Usage: $0 {statusline|observe|warmup|scheduled} [provider]" >&2
        echo "       $0 {reschedule|scheduler-check|status|providers|notify-test|version}" >&2
        echo "       $0 log <provider> <message> | notify <event> <message>" >&2
        echo "       $0 anchor [HH:MM|off]" >&2
        echo "       $0 model [agent [name|auto|default]]" >&2
        exit 2
        ;;
esac
FLUID_SCRIPT

chmod +x "$STAGE/fluid.sh"

# Make sure the script just generated parses
bash -n "$STAGE/fluid.sh"

# One file per agent. See docs/PROVIDERS.md for what these have to answer.
cat > "$STAGE/providers/claude.sh" <<'PROVIDER_CLAUDE'
# Claude Code. The plugin's hooks module hands over both windows whenever
# they change, so this provider pushes: no polling needed.
claude_label() {
    printf 'Claude Code\n'
}

claude_available() {
    command -v claude >/dev/null 2>&1
}

claude_capabilities() {
    printf 'keep alert\n'
}

# The status line payload, the shape the hooks module hands over too
claude_parse_limits() {
    jq -c '{
        window_seconds: 18000,
        used_percent: .rate_limits.five_hour.used_percentage,
        resets_at: .rate_limits.five_hour.resets_at,
        long_used_percent: .rate_limits.seven_day.used_percentage,
        long_resets_at: .rate_limits.seven_day.resets_at
    } | with_entries(select(.value != null))' 2>/dev/null
}

# Claude Code words a dead session differently from a refresh that merely
# failed this once ("session expired and could not be refreshed") or lost the
# cross-process refresh lock to another Claude Code. Only the first means
# anyone has to sign in again; the others are worth a retry, not a message.
claude_auth_failed() {
    grep -Eqi 'refresh token.*no longer valid|run /login|token_revoked|not logged in|invalid_credential'
}

claude_cheap_model() {
    printf 'haiku\n'
}

# The smallest request that still opens a window: one turn, no tools, nothing
# written to session history. No model given means Claude Code picks.
claude_warmup() {
    local model="${1:-}"
    local args=(--safe-mode -p --tools "" --no-session-persistence --max-turns 1)

    [[ -n "$model" ]] && args+=(--model "$model")

    with_timeout 180 claude "${args[@]}" 'Reply only OK.' 2>&1
}
PROVIDER_CLAUDE

cat > "$STAGE/providers/codex.sh" <<'PROVIDER_CODEX'
# Codex. It has no status line hook to push readings, but it records its
# limits in every session log, so this provider is polled instead.
codex_label() {
    printf 'Codex\n'
}

codex_available() {
    command -v codex >/dev/null 2>&1
}

codex_capabilities() {
    printf 'keep alert\n'
}

# primary is the short window, secondary the long one; both carry their own
# length, so nothing here assumes five hours
codex_parse_limits() {
    jq -c '{
        window_seconds: (if .rate_limits.primary.window_minutes
                         then .rate_limits.primary.window_minutes * 60 else null end),
        used_percent: .rate_limits.primary.used_percent,
        resets_at: .rate_limits.primary.resets_at,
        long_used_percent: .rate_limits.secondary.used_percent,
        long_resets_at: .rate_limits.secondary.resets_at
    } | with_entries(select(.value != null))' 2>/dev/null
}

# The last limits written to the newest session log. As current as the user's
# last turn, which is enough: a warmup corrects the estimate afterwards.
codex_pull_limits() {
    local newest

    newest="$(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -1)"
    [[ -n "$newest" ]] || return 1

    reverse_lines "$newest" |
        jq -cR 'fromjson? | select(.payload.rate_limits != null) | {rate_limits: .payload.rate_limits}' 2>/dev/null |
        head -1
}

codex_warmup() {
    local model="${1:-}"
    local args=(exec --skip-git-repo-check -s read-only)

    [[ -n "$model" ]] && args+=(-m "$model")

    with_timeout 180 codex "${args[@]}" 'Reply only OK.' 2>&1
}
PROVIDER_CODEX

cat > "$STAGE/providers/agy.sh" <<'PROVIDER_AGY'
# Antigravity. Its status line hook pushes quota on every refresh, like Claude
# Code, but reports what is left rather than what is used, as RFC 3339 times,
# split across several buckets.
agy_label() {
    printf 'Antigravity\n'
}

agy_available() {
    command -v agy >/dev/null 2>&1
}

agy_capabilities() {
    printf 'keep alert\n'
}

# Buckets are named by the window they belong to (gemini-5h, 3p-weekly, ...).
# Take the tightest of each kind: whichever runs out first is what stops you.
agy_parse_limits() {
    jq -c '
        def buckets(suffix):
            (.quota // {}) | to_entries | map(select(.key | endswith(suffix))) | map(.value);
        def pct(bs): 100 - (([bs[].remaining_fraction] | min) * 100) | . * 100 | round / 100;
        def first_reset(bs): [bs[].reset_time | fromdateiso8601] | min;

        buckets("-5h") as $short
        | buckets("-weekly") as $long
        | {
            window_seconds: 18000,
            used_percent: (if ($short | length) > 0 then pct($short) else null end),
            resets_at: (if ($short | length) > 0 then first_reset($short) else null end),
            long_used_percent: (if ($long | length) > 0 then pct($long) else null end),
            long_resets_at: (if ($long | length) > 0 then first_reset($long) else null end)
          }
        | with_entries(select(.value != null))' 2>/dev/null
}

agy_warmup() {
    local model="${1:-}"
    local args=(-p)

    [[ -n "$model" ]] && args+=(--model "$model")

    with_timeout 180 agy "${args[@]}" 'Reply only OK.' 2>&1
}
PROVIDER_AGY

for _provider in "$STAGE/providers"/*.sh; do
    bash -n "$_provider"
done

if is_installed; then
    echo "Existing installation detected. Removing it first..."
fi

# Upgrade clears settings and at jobs exactly as uninstall does, but keeps
# what is still running (reset times, failure and notification state), the
# user's notifier (it holds their credentials), the anchor and the log
# The wrapped commands live under state/, which is kept anyway
KEEP=("$(basename "$STATE")" "$(basename "$NOTIFY")" "$(basename "$ANCHOR")" "fluid.log")
REMOVED=1
remove_installation "${KEEP[@]}"

mkdir -p "$BASE" "$STATE" "$PROVIDERS"

mv "$STAGE/fluid.sh" "$BIN"
mv "$STAGE/providers"/*.sh "$PROVIDERS/"

# Install the notifier samples when they are reachable from this script.
# npx puts a symlink in node_modules/.bin, so resolve that first.
SCRIPT_SRC="${BASH_SOURCE[0]}"
if [[ -L "$SCRIPT_SRC" ]]; then
    SCRIPT_SRC="$(readlink -f "$SCRIPT_SRC" 2>/dev/null || readlink "$SCRIPT_SRC")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"

if compgen -G "$SCRIPT_DIR/notify/*.sample" >/dev/null; then
    mkdir -p "$BASE/notify"
    cp -p "$SCRIPT_DIR/notify"/*.sample "$BASE/notify/"
fi

# Removal has already turned any old wrapper of ours back into the user's own
# command, so whatever statusLine each agent has now is the one to wrap.
# Inside another program's chain, removal kept the command we render instead.
for _id in $(wrapped_agents); do
    in_chain "$_id" && continue
    _file="$(agent_settings "$_id")" || continue
    [[ -f "$_file" ]] || continue

    _current="$(status_command "$_file")"
    if [[ -n "$_current" && "$_current" != *"$MARKER"* ]]; then
        mkdir -p "$STATE/$_id"
        printf '%s\n' "$_current" > "$(agent_orig "$_id")"
    fi
done
unset _id _file _current

# Removal above has already taken out every entry of ours; a status line
# wrapper is all Fluid adds, and inside another program's chain not even
# that. Each agent gets its own id on the command, so the wrapper knows whose
# reading it is handling.
for _id in $(wrapped_agents); do
    in_chain "$_id" && continue
    _file="$(agent_settings "$_id")" || continue
    [[ -f "$_file" ]] || continue

    edit_json "$_file" --arg status_cmd "$BIN statusline $_id" '
        .statusLine = (
            (.statusLine // {})
            + {
                "type": "command",
                "command": $status_cmd
            }
        )
    '
done
unset _id _file


# Removal dropped the old at job; put the run the previous version had
# planned back on the new one
if ! "$BIN" reschedule; then
    echo "Warning: could not schedule the next run (see $BASE/fluid.log)." >&2
    echo "         Claude Code and Antigravity try again on their next reading;" >&2
    echo "         for Codex, run the installer again once the scheduler works." >&2
fi

# `at` accepts jobs whether or not atd runs them, so check the daemon itself
SCHEDULER_RC=0
"$BIN" scheduler-check || SCHEDULER_RC=$?

INSTALL_DONE=1

echo
echo "Fluid installed."
if (( SCHEDULER_RC == 1 )); then
    echo "Warning: atd is not running, so nothing Fluid schedules will run." >&2
    echo "         Start it with: sudo systemctl enable --now atd" >&2
fi
# Claude Code's readings and resume come only from the plugin's hooks module,
# which sets FLUID_MOD in the session it runs in
if command -v claude >/dev/null 2>&1; then
    if [[ "${FLUID_HOOK:-}" != plugin ]]; then
        echo "Claude Code: windows are kept on estimates only. For its readings and resume,"
        echo "             install the plugin: /plugin install fluid --marketplace MrJasonZhou/fluid"
    elif [[ -z "${FLUID_MOD:-}" ]]; then
        echo "Claude Code: the plugin's hooks module did not load in this session, so windows"
        echo "             are kept on estimates only until it does (hooks modules are still"
        echo "             rolling out to accounts)."
    fi
fi
if [[ -n "$CHAINED" ]]; then
    echo "A status line belonging to another program already calls Fluid; it was left as it is:"
    printf '%s' "$CHAIN_COMMANDS" | sed 's/^/  /'
fi
echo "Agents          : $("$BIN" providers | awk '/installed/ {printf "%s ", $1}')"
echo "Main script     : $BIN"
echo
echo "Check:"
echo "  $BIN status"

