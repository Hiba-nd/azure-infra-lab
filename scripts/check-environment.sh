#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: bash scripts/check-environment.sh [--help]\n'
    printf 'Check Linux prerequisites without changing the host configuration.\n'
}

die() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

if (( $# > 0 )); then
    if (( $# == 1 )) && [[ $1 == --help ]]; then
        usage
        exit 0
    fi
    printf 'ERROR: unexpected arguments; use --help\n' >&2
    exit 2
fi

for tool in uname id awk df tar mktemp rm; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done

[[ $(uname -s) == Linux ]] || die 'Linux is required; use the lab container or a Linux VM'
(( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer is required'
[[ -r /etc/os-release ]] || die '/etc/os-release is not readable'
[[ -r /proc/meminfo && -r /proc/loadavg ]] || die 'required /proc files are not readable'

# This file is supplied by the operating system, not by the caller.
source /etc/os-release

probe_file=$(mktemp) || die 'cannot create a temporary file; check TMPDIR and permissions'
trap 'rm -f -- "$probe_file"' EXIT
printf 'cloud-lab-probe\n' > "$probe_file" || die 'cannot write to the temporary directory'
IFS= read -r probe_value < "$probe_file"
[[ $probe_value == cloud-lab-probe ]] || die 'temporary file read-back failed'

printf 'os=%s\n' "${PRETTY_NAME:-unknown}"
printf 'kernel=%s\n' "$(uname -r)"
printf 'bash=%s\n' "$BASH_VERSION"
printf 'uid=%s\n' "$(id -u)"
printf 'procfs=readable\n'
printf 'temporary_directory=writable\n'
printf 'status=ok\n'
