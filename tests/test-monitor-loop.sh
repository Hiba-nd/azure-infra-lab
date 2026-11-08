#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
watch_pid=''
cleanup() {
    if [[ -n $watch_pid ]]; then
        kill -TERM -- "$watch_pid" 2>/dev/null || true
        wait "$watch_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT
trap 'exit 143' TERM
mkdir -p "$test_dir/private"
runner=("$BASH" "$repo_root/scripts/monitor-loop.sh")
passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; cat "$test_dir/stderr" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
expect_code() {
    local expected=$1 status=0
    shift
    "$@" > "$test_dir/stdout" 2> "$test_dir/stderr" || status=$?
    [[ $status == "$expected" ]] || fail "expected exit $expected, got $status: $*"
    pass "exit $expected: $*"
}

child_named() {
    local parent=$1 expected=$2 status_file key value name ppid pid_path
    for status_file in /proc/[0-9]*/status; do
        name='' ppid=''
        while read -r key value _; do
            case $key in
                Name:) name=$value ;;
                PPid:) ppid=$value ;;
            esac
            if [[ -n $name && -n $ppid ]]; then break; fi
        done 2>/dev/null < "$status_file" || continue
        if [[ $name == "$expected" && $ppid == "$parent" ]]; then
            pid_path=${status_file%/status}
            printf '%s\n' "${pid_path##*/}"
            return 0
        fi
    done
    return 1
}

PATH=/nonexistent expect_code 0 "${runner[@]}" --help
PATH=/nonexistent expect_code 3 "${runner[@]}" --count 1
expect_code 3 "${runner[@]}" --unknown
expect_code 3 "${runner[@]}" --delay
for bad in -1 01 1000000; do expect_code 3 "${runner[@]}" --count "$bad"; done
for bad in 0 301; do expect_code 3 "${runner[@]}" --timeout "$bad"; done
for bad in 0 invalid 3601; do expect_code 3 "${runner[@]}" --delay "$bad"; done

TMPDIR="$test_dir/private" expect_code 2 "${runner[@]}" --count 2 --delay 0.1 -- --interval 0.1 --process zzz-lab-missing
[[ $(grep -c '^sample=' "$test_dir/stdout") == 2 ]] || fail 'finite run did not produce exactly two samples'
[[ $(grep -c '^status=CRITICAL$' "$test_dir/stdout") == 2 ]] || fail 'runner did not preserve critical results'
[[ ! -s $test_dir/stderr ]] || fail 'unexpected diagnostic from finite run'
pass 'critical checks do not stop subsequent samples'
[[ -z $(find "$test_dir/private" -mindepth 1 -print -quit) ]] || fail 'temporary report leaked on normal exit'
pass 'temporary reports cleaned after normal exit'

TMPDIR="$test_dir/private" expect_code 3 "${runner[@]}" --count 1 --timeout 1 -- --interval 60
[[ $(grep -c '^status=UNKNOWN$' "$test_dir/stdout") == 1 ]] || fail 'timeout must produce one UNKNOWN result'
! grep -Eq '^status=(OK|WARNING|CRITICAL)$' "$test_dir/stdout" || fail 'timeout reused a partial result'
grep -q 'health check exited with status 124' "$test_dir/stderr" || fail 'timeout diagnostic missing'
pass 'real check deadline produces UNKNOWN without a partial success report'
[[ -z $(find "$test_dir/private" -mindepth 1 -print -quit) ]] || fail 'temporary report leaked on timeout'
pass 'temporary reports cleaned after timeout'

# Stub only the collector boundary to test severity history independently of host load.
timeout() {
    local counter
    IFS= read -r counter < "$MONITOR_TEST_COUNTER"
    printf '%d\n' "$((counter + 1))" > "$MONITOR_TEST_COUNTER"
    if (( counter == 0 )); then printf 'status=CRITICAL\n'; return 2; fi
    printf 'status=OK\n'
}
export -f timeout
printf '0\n' > "$test_dir/counter"
MONITOR_TEST_COUNTER="$test_dir/counter" expect_code 2 "${runner[@]}" --count 2 --delay 0.1
[[ $(grep -c '^status=CRITICAL$' "$test_dir/stdout") == 1 ]] || fail 'controlled critical sample missing'
[[ $(grep -c '^status=OK$' "$test_dir/stdout") == 1 ]] || fail 'controlled recovery sample missing'
pass 'controlled recovery retains the worst status across samples'
unset -f timeout

timeout() { printf 'status=CRITICAL\n'; return 0; }
export -f timeout
expect_code 3 "${runner[@]}" --count 1
grep -qx 'status=UNKNOWN' "$test_dir/stdout" || fail 'inconsistent report was not rejected'
pass 'inconsistent collector exit code and report produce UNKNOWN'
unset -f timeout

# Keep a valid collection slower than the old five-second readiness budget.
MONITOR_TEST_SLEEP_BIN=$(type -P sleep)
export MONITOR_TEST_SLEEP_BIN
sleep() {
    if [[ $1 == 0.1 ]]; then
        "$MONITOR_TEST_SLEEP_BIN" 6
    else
        exec "$MONITOR_TEST_SLEEP_BIN" "$@"
    fi
}
export -f sleep
TMPDIR="$test_dir/private" "${runner[@]}" --timeout 10 --delay 60 -- --interval 0.1 --process bash > "$test_dir/stdout" 2> "$test_dir/stderr" &
watch_pid=$!
unset -f sleep
sleep_pid=''
readiness_deadline=$((SECONDS + 15))
while (( SECONDS < readiness_deadline )); do
    kill -0 "$watch_pid" 2>/dev/null || fail 'runner exited before the delay between samples'
    if grep -q '^sample=1$' "$test_dir/stdout"; then
        sleep_pid=$(child_named "$watch_pid" sleep) || sleep_pid=''
        if [[ -n $sleep_pid ]]; then break; fi
    fi
    sleep 0.05
done
[[ -n $sleep_pid ]] || fail 'runner did not reach the delay between samples'
grep -qx 'process_state=present' "$test_dir/stdout" || fail 'slow collection did not finish its report'
kill -0 "$sleep_pid" 2>/dev/null || fail 'delay child exited before SIGTERM'
pass 'a valid collection longer than five seconds reaches a live delay child'
kill -TERM -- "$watch_pid"
status=0
wait "$watch_pid" || status=$?
watch_pid=''
[[ $status == 143 ]] || fail 'runner did not preserve SIGTERM exit status'
! kill -0 "$sleep_pid" 2>/dev/null || fail 'runner left its sleep child behind'
pass 'SIGTERM stops the runner and its active delay child'
[[ -z $(find "$test_dir/private" -mindepth 1 -print -quit) ]] || fail 'temporary report leaked on SIGTERM'
pass 'temporary reports cleaned on SIGTERM'

TMPDIR="$test_dir/private" "${runner[@]}" --timeout 300 -- --interval 60 > "$test_dir/stdout" 2> "$test_dir/stderr" &
watch_pid=$!
collector_sleep=''
readiness_deadline=$((SECONDS + 15))
while (( SECONDS < readiness_deadline )); do
    kill -0 "$watch_pid" 2>/dev/null || fail 'runner exited before the sampling wait'
    timeout_pid=$(child_named "$watch_pid" timeout) || timeout_pid=''
    if [[ -n $timeout_pid ]]; then
        collector_pid=$(child_named "$timeout_pid" bash) || collector_pid=''
        if [[ -n $collector_pid ]]; then
            collector_sleep=$(child_named "$collector_pid" sleep) || collector_sleep=''
            if [[ -n $collector_sleep ]]; then break; fi
        fi
    fi
    sleep 0.05
done
[[ -n $collector_sleep ]] || fail 'runner did not reach an active CPU sampling wait'
kill -TERM -- "$watch_pid"
status=0
wait "$watch_pid" || status=$?
watch_pid=''
[[ $status == 143 ]] || fail 'SIGTERM during collection returned the wrong exit code'
for child in "$timeout_pid" "$collector_pid" "$collector_sleep"; do
    ! kill -0 "$child" 2>/dev/null || fail "runner left collector descendant $child behind"
done
pass 'SIGTERM during collection stops timeout, collector, and sampling sleep'
[[ -z $(find "$test_dir/private" -mindepth 1 -print -quit) ]] || fail 'temporary report leaked during collector shutdown'
pass 'temporary reports cleaned during collector shutdown'

printf '\n%d sampler checks passed\n' "$passed"
