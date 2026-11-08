#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )) || { (( $# == 1 )) && [[ $1 != --lab ]]; }; then
    printf 'Usage: bash tests/run.sh [--lab]\n' >&2
    exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check_script="$repo_root/scripts/check-environment.sh"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/probes"
passed=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -s $test_dir/stderr ]]; then
        cat "$test_dir/stderr" >&2
    fi
    exit 1
}

pass() {
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$1"
}

run_check() {
    status=0
    "$BASH" "$check_script" "$@" > "$test_dir/stdout" 2> "$test_dir/stderr" || status=$?
}

for script in "$repo_root"/scripts/*.sh "$repo_root"/scripts/lib/*.sh "$repo_root"/tests/*.sh; do
    "$BASH" -n "$script" || fail "Bash syntax: $script"
done
pass 'Bash syntax'

PATH=/nonexistent run_check --help
[[ $status == 0 && ! -s $test_dir/stderr ]] || fail 'help exit status or stderr'
grep -q '^Usage:' "$test_dir/stdout" || fail 'help output'
pass 'help works without running checks'

run_check --unknown
[[ $status == 2 && ! -s $test_dir/stdout ]] || fail 'invalid argument contract'
grep -q 'unexpected arguments' "$test_dir/stderr" || fail 'invalid argument diagnostic'
pass 'invalid arguments return 2 on stderr'

PATH=/nonexistent run_check
[[ $status == 1 && ! -s $test_dir/stdout ]] || fail 'missing dependency contract'
grep -q 'required command not found: uname' "$test_dir/stderr" || fail 'missing dependency diagnostic'
pass 'missing dependency returns 1 with a diagnostic'

uname() { printf 'Darwin\n'; }
export -f uname
run_check
unset -f uname
[[ $status == 1 && ! -s $test_dir/stdout ]] || fail 'non-Linux platform contract'
grep -q 'Linux is required' "$test_dir/stderr" || fail 'non-Linux platform diagnostic'
pass 'simulated non-Linux platform is rejected'

TMPDIR="$test_dir/probes" run_check
[[ $status == 0 && ! -s $test_dir/stderr ]] || fail 'Linux environment check'
for key in os kernel bash uid; do
    grep -Eq "^${key}=.+$" "$test_dir/stdout" || fail "missing report field: $key"
done
grep -qx 'status=ok' "$test_dir/stdout" || fail 'successful report status'
pass 'real Linux environment check and report'

[[ -z $(find "$test_dir/probes" -mindepth 1 -print -quit) ]] || fail 'temporary probe leaked'
pass 'environment check cleans up its temporary file'

TMPDIR="$test_dir/does-not-exist" run_check
[[ $status == 1 && ! -s $test_dir/stdout ]] || fail 'invalid temporary directory contract'
grep -q 'cannot create a temporary file' "$test_dir/stderr" || fail 'temporary directory diagnostic'
pass 'unavailable temporary directory returns 1'

if [[ ${1:-} == --lab ]]; then
    [[ $(id -u) != 0 ]] || fail 'lab must run as a non-root user'
    pass 'lab runs without root'

    if (printf 'probe' > "$repo_root/scripts/.write-probe") 2> "$test_dir/stderr"; then
        rm -f -- "$repo_root/scripts/.write-probe"
        fail 'repository mount is writable'
    fi
    pass 'repository mount rejects writes'

    if (printf 'probe' > /etc/.cloud-lab-write-probe) 2> "$test_dir/stderr"; then
        rm -f -- /etc/.cloud-lab-write-probe
        fail 'system directory is writable'
    fi
    pass 'system directory rejects writes'

    awk '$5 == "/" && $6 ~ /(^|,)ro(,|$)/ { found = 1 } END { exit !found }' /proc/self/mountinfo \
        || fail 'root filesystem is not mounted read-only'
    awk '$5 == "/lab/scripts" && $6 ~ /(^|,)ro(,|$)/ { found = 1 } END { exit !found }' /proc/self/mountinfo \
        || fail 'scripts directory is not mounted read-only'
    pass 'root filesystem and scripts mount are read-only'

    grep -Eq '^CapEff:[[:space:]]+0+$' /proc/self/status || fail 'effective capabilities are present'
    grep -Eq '^CapBnd:[[:space:]]+0+$' /proc/self/status || fail 'capability bounding set is not empty'
    grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status || fail 'no-new-privileges is disabled'
    pass 'capabilities are dropped and privilege escalation is disabled'

    for interface in /sys/class/net/*; do
        [[ ${interface##*/} == lo ]] || fail "unexpected network interface: $interface"
    done
    pass 'only the loopback network interface is present'
fi

printf '\n%d checks passed\n' "$passed"
"$BASH" "$repo_root/tests/test-health.sh"
"$BASH" "$repo_root/tests/test-monitor-loop.sh"
"$BASH" "$repo_root/tests/test-backup.sh"
