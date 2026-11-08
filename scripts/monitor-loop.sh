#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
    printf '%s\n' 'Usage: bash scripts/monitor-loop.sh [options] [-- health-check options]
  --delay SECONDS    Wait between completed samples, 0.1..3600 (default: 30)
  --count NUMBER     Stop after this many samples; 0 runs continuously (default: 0)
  --timeout SECONDS  Deadline per check, integer 1..300 (default: 10)
  --help
Reports go to stdout; diagnostics go to stderr. A finite run returns its worst status.
SIGINT/SIGTERM stop the runner and its current child with exit codes 130/143.'
}

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 3; }
require_value() { (( $# >= 2 )) && [[ -n $2 ]] || fail "missing value for $1"; }

delay=30 count=0 deadline=10
while (( $# )); do
    case $1 in
        --help) usage; exit 0 ;;
        --delay) require_value "$@"; delay=$2; shift 2 ;;
        --count) require_value "$@"; count=$2; shift 2 ;;
        --timeout) require_value "$@"; deadline=$2; shift 2 ;;
        --) shift; break ;;
        *) fail "unexpected argument: $1; use -- before health-check options" ;;
    esac
done

for tool in uname awk timeout sleep date dirname mktemp rm rmdir cat grep; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done
[[ $(uname -s) == Linux ]] || fail 'Linux is required'
(( BASH_VERSINFO[0] >= 4 )) || fail 'Bash 4 or newer is required'
[[ $count =~ ^(0|[1-9][0-9]{0,5})$ ]] || fail 'count must be 0..999999, without leading zeros'
[[ $deadline =~ ^[1-9][0-9]{0,2}$ ]] && (( deadline <= 300 )) || fail 'timeout must be an integer from 1 to 300'
[[ $delay =~ ^(0|[1-9][0-9]*)(\.[0-9]{1,3})?$ ]] \
    && awk -v n="$delay" 'BEGIN { exit !(n >= 0.1 && n <= 3600) }' \
    || fail 'delay must be 0.1..3600 seconds, with at most three decimal places'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || fail 'cannot locate the script directory'

state_dir=''
child_pid=''
cleanup() {
    if [[ -n $child_pid ]]; then
        kill -TERM -- "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    if [[ -n $state_dir ]]; then
        rm -f -- "$state_dir/report"
        rmdir -- "$state_dir"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
state_dir=$(mktemp -d) || fail 'cannot create private temporary storage'

sample=0
worst=0
names=(OK WARNING CRITICAL UNKNOWN)
while :; do
    check_status=0
    timeout --kill-after=1s "${deadline}s" "$BASH" "$script_dir/health-check.sh" "$@" > "$state_dir/report" &
    child_pid=$!
    wait "$child_pid" || check_status=$?
    child_pid=''
    sample=$((sample + 1))
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || fail 'cannot read the system clock'
    printf 'sample=%d\nsample_timestamp_utc=%s\n' "$sample" "$timestamp"
    if (( check_status <= 3 )) \
        && [[ $(grep -c '^status=' "$state_dir/report") == 1 ]] \
        && grep -qx "status=${names[check_status]}" "$state_dir/report"; then
        cat -- "$state_dir/report"
    else
        printf 'ERROR: health check exited with status %d or produced an invalid report\n' "$check_status" >&2
        printf 'status=UNKNOWN\n'
        check_status=3
    fi
    printf '\n'
    if (( check_status > worst )); then worst=$check_status; fi
    if (( count != 0 && sample >= count )); then exit "$worst"; fi

    delay_status=0
    sleep "$delay" &
    child_pid=$!
    wait "$child_pid" || delay_status=$?
    child_pid=''
    (( delay_status == 0 )) || fail 'delay between checks failed'
done
