#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
    printf '%s\n' 'Usage: bash scripts/health-check.sh [options]
  --interval SECONDS       CPU sampling interval, 0.1..60 (default: 1)
  --disk PATH              Filesystem to check (default: /)
  --process NAME           Require an exact Linux comm name, up to 15 ASCII characters
  --cpu-warning PERCENT    Default: 80
  --cpu-critical PERCENT   Default: 90
  --memory-warning PERCENT Default: 80
  --memory-critical PERCENT Default: 90
  --disk-warning PERCENT   Default: 80
  --disk-critical PERCENT  Default: 90
  --help
Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (including invalid configuration).'
}

unknown() {
    printf 'ERROR: %s\n' "$1" >&2
    printf 'status=UNKNOWN\n'
    exit 3
}

require_value() {
    (( $# >= 2 )) && [[ -n $2 ]] || unknown "missing value for $1"
}

interval=1
disk=/
process=''
cpu_warning=80 cpu_critical=90
memory_warning=80 memory_critical=90
disk_warning=80 disk_critical=90

while (( $# )); do
    case $1 in
        --help) usage; exit 0 ;;
        --interval) require_value "$@"; interval=$2; shift 2 ;;
        --disk) require_value "$@"; disk=$2; shift 2 ;;
        --process) require_value "$@"; process=$2; shift 2 ;;
        --cpu-warning) require_value "$@"; cpu_warning=$2; shift 2 ;;
        --cpu-critical) require_value "$@"; cpu_critical=$2; shift 2 ;;
        --memory-warning) require_value "$@"; memory_warning=$2; shift 2 ;;
        --memory-critical) require_value "$@"; memory_critical=$2; shift 2 ;;
        --disk-warning) require_value "$@"; disk_warning=$2; shift 2 ;;
        --disk-critical) require_value "$@"; disk_critical=$2; shift 2 ;;
        *) unknown "unexpected argument: $1" ;;
    esac
done

for tool in uname awk df timeout sleep date dirname; do
    command -v "$tool" >/dev/null 2>&1 || unknown "required command not found: $tool"
done
[[ $(uname -s) == Linux ]] || unknown 'Linux is required'
(( BASH_VERSINFO[0] >= 4 )) || unknown 'Bash 4 or newer is required'

for threshold in "$cpu_warning" "$cpu_critical" "$memory_warning" "$memory_critical" "$disk_warning" "$disk_critical"; do
    [[ $threshold =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( threshold <= 100 )) \
        || unknown 'thresholds must be integers from 0 to 100, without leading zeros'
done
(( cpu_warning < cpu_critical && memory_warning < memory_critical && disk_warning < disk_critical )) \
    || unknown 'each warning threshold must be lower than its critical threshold'
[[ $interval =~ ^(0|[1-9][0-9]*)(\.[0-9]{1,3})?$ ]] \
    && awk -v n="$interval" 'BEGIN { exit !(n >= 0.1 && n <= 60) }' \
    || unknown 'interval must be 0.1..60 seconds, with at most three decimal places'
[[ $disk != *$'\n'* && $disk != *$'\r'* ]] || unknown 'disk path must not contain line breaks'
[[ -z $process || $process =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] \
    || unknown 'process must be an exact comm name of 1..15 ASCII letters, digits, or _.:-'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || unknown 'cannot locate the script directory'
source "$script_dir/lib/metrics.sh" || unknown 'cannot load the metrics library'
trap 'unknown "interrupted by SIGINT"' INT
trap 'unknown "interrupted by SIGTERM"' TERM

before=$(health_cpu_snapshot /proc/stat) || unknown 'cannot read valid CPU counters'
sleep "$interval" || unknown 'CPU sampling wait failed'
after=$(health_cpu_snapshot /proc/stat) || unknown 'cannot read valid CPU counters'
cpu=$(health_cpu_percent "$before" "$after") || unknown 'CPU counters did not advance or moved backwards'
memory=$(health_memory_percent /proc/meminfo) || unknown 'cannot read valid MemTotal and MemAvailable values'
disk_used=$(health_disk_percent "$disk") || unknown 'filesystem measurement failed or exceeded its 5-second timeout'

overall=0
cpu_state=0; health_percent_status "$cpu" "$cpu_warning" "$cpu_critical" || cpu_state=$?
memory_state=0; health_percent_status "$memory" "$memory_warning" "$memory_critical" || memory_state=$?
disk_state=0; health_percent_status "$disk_used" "$disk_warning" "$disk_critical" || disk_state=$?
for state in "$cpu_state" "$memory_state" "$disk_state"; do
    (( state <= 2 )) || unknown 'invalid percentage returned by a collector'
    if (( state > overall )); then overall=$state; fi
done

process_state=0
if [[ -n $process ]]; then
    health_process_present "$process" || process_state=$?
    (( process_state != 2 )) || unknown 'process state is not readable'
    if (( process_state == 1 )); then overall=2; fi
fi

timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || unknown 'cannot read the system clock'
names=(OK WARNING CRITICAL UNKNOWN)
printf 'timestamp_utc=%s\n' "$timestamp"
printf 'cpu_percent=%s\ncpu_status=%s\n' "$cpu" "${names[cpu_state]}"
printf 'memory_percent=%s\nmemory_status=%s\n' "$memory" "${names[memory_state]}"
printf 'disk_percent=%s\ndisk_status=%s\n' "$disk_used" "${names[disk_state]}"
if [[ -n $process ]]; then
    printf 'process_name=%s\n' "$process"
    if (( process_state == 0 )); then printf 'process_state=present\n'; else printf 'process_state=missing\n'; fi
fi
printf 'status=%s\n' "${names[overall]}"
exit "$overall"
