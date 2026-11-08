#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/metrics.sh"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
passed=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
expect_output() {
    local expected=$1 actual
    shift
    actual=$("$@") || fail "command failed: $*"
    [[ $actual == "$expected" ]] || fail "expected '$expected', got '$actual': $*"
    pass "$*"
}
expect_code() {
    local expected=$1 status=0
    shift
    "$@" > "$test_dir/stdout" 2> "$test_dir/stderr" || status=$?
    [[ $status == "$expected" ]] || fail "expected exit $expected, got $status: $*"
    pass "exit $expected: $*"
}
check=("$BASH" "$repo_root/scripts/health-check.sh")

printf 'cpu 100 0 50 800 20 10 20 0 90 0\ncpu0 0 0 0 0\n' > "$test_dir/stat"
expect_output '100 0 50 800 20 10 20 0' health_cpu_snapshot "$test_dir/stat"
expect_output '50.00' health_cpu_percent '100 0 50 800 20 10 20 0' '120 0 60 840 30 20 30 0'
expect_output '0.00' health_cpu_percent '1 0 0 10 0 0 0 0' '1 0 0 20 0 0 0 0'
expect_output '100.00' health_cpu_percent '1 0 0 10 0 0 0 0' '11 0 0 10 0 0 0 0'
expect_code 1 health_cpu_percent '1 0 0 10 0 0 0 0' '1 0 0 10 0 0 0 0'
expect_code 1 health_cpu_percent '100 0 0 10 0 0 0 0' '90 0 0 30 0 0 0 0'
expect_code 1 health_cpu_percent '1 0 0 10 5 0 0 0' '2 0 0 20 4 0 0 0'
printf 'cpu0 1 2 invalid\n' > "$test_dir/stat"
expect_code 1 health_cpu_snapshot "$test_dir/stat"
printf 'cpu 1 2 3 4 broken 6 7 8\n' > "$test_dir/stat"
expect_code 1 health_cpu_snapshot "$test_dir/stat"

printf 'MemTotal: 1000 kB\nMemFree: 10 kB\nMemAvailable: 600 kB\n' > "$test_dir/meminfo"
expect_output '40.00' health_memory_percent "$test_dir/meminfo"
printf 'MemTotal: 1000 kB\nMemAvailable: 0 kB\n' > "$test_dir/meminfo"
expect_output '100.00' health_memory_percent "$test_dir/meminfo"
printf 'MemTotal: 0 kB\nMemAvailable: 0 kB\n' > "$test_dir/meminfo"
expect_code 1 health_memory_percent "$test_dir/meminfo"
printf 'MemTotal: 1000 kB\n' > "$test_dir/meminfo"
expect_code 1 health_memory_percent "$test_dir/meminfo"
printf 'MemTotal: 1000 kB\nMemAvailable: 1001 kB\n' > "$test_dir/meminfo"
expect_code 1 health_memory_percent "$test_dir/meminfo"
printf 'MemTotal: 1000 kB\nMemAvailable: 2 MB\n' > "$test_dir/meminfo"
expect_code 1 health_memory_percent "$test_dir/meminfo"
printf 'MemTotal: 1000 kB\nMemAvailable: 500 kB\nMemAvailable: 500 kB\n' > "$test_dir/meminfo"
expect_code 1 health_memory_percent "$test_dir/meminfo"

expect_output '85' health_parse_disk_percent <<< $'Use%\n 85%'
expect_output '105' health_parse_disk_percent <<< $'Use%\n105%'
expect_code 1 health_parse_disk_percent <<< $'Use%\n-'
expect_code 1 health_parse_disk_percent <<< $'Use%\n85%\n90%'
expect_code 1 health_parse_disk_percent <<< ''
expect_code 0 health_percent_status 79.99 80 90
expect_code 1 health_percent_status 80 80 90
expect_code 2 health_percent_status 90 80 90
expect_code 2 health_percent_status 105 80 90
expect_code 3 health_percent_status invalid 80 90
expect_code 3 health_percent_status 30 90 80

mkdir -p "$test_dir/proc/123" "$test_dir/proc/456"
printf 'nginx\n' > "$test_dir/proc/123/comm"
printf 'Name:\tnginx\nState:\tS (sleeping)\n' > "$test_dir/proc/123/status"
printf 'nginx-worker\n' > "$test_dir/proc/456/comm"
printf 'State:\tS (sleeping)\n' > "$test_dir/proc/456/status"
expect_code 0 health_process_present nginx "$test_dir/proc"
expect_code 1 health_process_present ngin "$test_dir/proc"
printf 'State:\tZ (zombie)\n' > "$test_dir/proc/123/status"
expect_code 1 health_process_present nginx "$test_dir/proc"
printf 'State:\t?\n' > "$test_dir/proc/123/status"
expect_code 2 health_process_present nginx "$test_dir/proc"
expect_code 2 health_process_present nginx "$test_dir/absent-proc"

expect_code 0 "${check[@]}" --help
PATH=/nonexistent expect_code 0 "${check[@]}" --help
PATH=/nonexistent expect_code 3 "${check[@]}"
expect_code 3 "${check[@]}" --unknown
expect_code 3 "${check[@]}" --disk
for bad in -1 101 08 1.5 '1+1' 999999999999999999999; do
    expect_code 3 "${check[@]}" --cpu-warning "$bad"
done
expect_code 3 "${check[@]}" --cpu-warning 90 --cpu-critical 80
expect_code 3 "${check[@]}" --interval 0
expect_code 3 "${check[@]}" --interval 61
expect_code 3 "${check[@]}" --process 'a name with spaces'
expect_code 3 "${check[@]}" --disk "$test_dir/missing-disk" --interval 0.1
grep -qx 'status=UNKNOWN' "$test_dir/stdout" || fail 'collector failure must report UNKNOWN'
grep -q 'filesystem measurement failed' "$test_dir/stderr" || fail 'collector failure diagnostic missing'
pass 'collector errors cannot produce a healthy report'

status=0
"${check[@]}" --disk /tmp --process bash --interval 0.1 > "$test_dir/stdout" 2> "$test_dir/stderr" || status=$?
(( status <= 2 )) || fail 'live Linux health check could not collect metrics'
[[ ! -s $test_dir/stderr ]] || fail 'unexpected live health check diagnostic'
for metric in cpu memory disk; do
    grep -Eq "^${metric}_percent=[0-9]+([.][0-9]+)?$" "$test_dir/stdout" || fail "live $metric missing"
done
grep -qx 'process_state=present' "$test_dir/stdout" || fail 'live Bash process not found'
names=(OK WARNING CRITICAL)
grep -qx "status=${names[status]}" "$test_dir/stdout" || fail 'live report status disagrees with exit code'
pass 'live Linux CPU, memory, disk and process collection'

expect_code 2 "${check[@]}" --disk /tmp --process zzz-lab-missing --interval 0.1
grep -qx 'process_state=missing' "$test_dir/stdout" || fail 'missing process report'
grep -qx 'status=CRITICAL' "$test_dir/stdout" || fail 'missing process must be CRITICAL'
pass 'missing process overrides metric severities'

printf '\n%d health checks passed\n' "$passed"
