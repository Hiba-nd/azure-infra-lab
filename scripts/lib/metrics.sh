#!/usr/bin/env bash

health_cpu_snapshot() {
    awk '
        NR == 1 {
            if ($1 != "cpu" || NF < 9) exit 1
            for (i = 2; i <= 9; i++) if ($i !~ /^[0-9]+$/) exit 1
            print $2, $3, $4, $5, $6, $7, $8, $9
            valid = 1
            exit
        }
        END { if (!valid) exit 1 }
    ' "$1"
}

health_cpu_percent() {
    awk -v before="$1" -v after="$2" '
        BEGIN {
            if (split(before, b, " ") != 8 || split(after, a, " ") != 8) exit 1
            for (i = 1; i <= 8; i++) {
                if (b[i] !~ /^[0-9]+$/ || a[i] !~ /^[0-9]+$/ || a[i] < b[i]) exit 1
                delta[i] = a[i] - b[i]
                total += delta[i]
            }
            if (total <= 0) exit 1
            printf "%.2f\n", 100 * (total - delta[4] - delta[5]) / total
        }
    '
}

health_memory_percent() {
    awk '
        $1 == "MemTotal:" {
            totals++
            if (NF != 3 || $2 !~ /^[0-9]+$/ || $3 != "kB") invalid = 1
            total = $2
        }
        $1 == "MemAvailable:" {
            available_fields++
            if (NF != 3 || $2 !~ /^[0-9]+$/ || $3 != "kB") invalid = 1
            available = $2
        }
        END {
            if (invalid || totals != 1 || available_fields != 1 || total <= 0 || available > total) exit 1
            printf "%.2f\n", 100 * (total - available) / total
        }
    ' "$1"
}

health_parse_disk_percent() {
    awk '
        NR == 2 {
            if (NF != 1 || $1 !~ /^[0-9]+%$/) exit 1
            sub(/%$/, "", $1)
            value = $1
            valid = 1
        }
        END {
            if (!valid || NR != 2) exit 1
            print value
        }
    '
}

health_disk_percent() {
    timeout --kill-after=1s 5s df --output=pcent -- "$1" | health_parse_disk_percent
}

health_percent_status() {
    awk -v value="$1" -v warning="$2" -v critical="$3" '
        BEGIN {
            if (value !~ /^[0-9]+([.][0-9]+)?$/ || warning !~ /^[0-9]+$/ || critical !~ /^[0-9]+$/) exit 3
            if (warning < 0 || critical > 100 || warning >= critical) exit 3
            if (value >= critical) exit 2
            if (value >= warning) exit 1
            exit 0
        }
    '
}

health_process_present() {
    local name=$1 proc_root=${2:-/proc} comm_file comm key value state status_file
    [[ -d $proc_root && -r $proc_root && -x $proc_root ]] || return 2
    for comm_file in "$proc_root"/[0-9]*/comm; do
        [[ -r $comm_file ]] || continue
        IFS= read -r comm 2>/dev/null < "$comm_file" || continue
        [[ $comm == "$name" ]] || continue
        status_file=${comm_file%/comm}/status
        [[ -e $status_file ]] || continue
        [[ -r $status_file ]] || return 2
        state=''
        while read -r key value _; do
            if [[ $key == State: ]]; then
                state=$value
                break
            fi
        done 2>/dev/null < "$status_file" || return 2
        case $state in
            Z|X|x) continue ;;
            R|S|D|T|t|W|I|P) return 0 ;;
            *) return 2 ;;
        esac
    done
    return 1
}
