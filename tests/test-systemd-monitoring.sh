#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"
service=azure-infra-health.service
timer=azure-infra-health.timer
unit_dir=/etc/systemd/system
complete_report='^status=(OK|WARNING|CRITICAL)$'

for unit in "$service" "$timer"; do
    if [[ $(systemctl show --property=LoadState --value "$unit") != not-found ||
        -e $unit_dir/$unit || -L $unit_dir/$unit ]]; then
        printf 'Expected a disposable systemd host without %s\n' "$unit" >&2
        exit 1
    fi
done

test_dir=$(mktemp -d)
install_dir=''
process_pid=''
started="@$(date +%s)"
cleanup() {
    local status=$?
    if (( status != 0 )); then
        systemctl status --no-pager "$timer" "$service" >&2 || true
        sudo -n journalctl -b -u "$service" --since "$started" --no-pager >&2 || true
    fi
    if [[ -n $install_dir ]]; then
        sudo -n systemctl disable --now "$timer" >/dev/null 2>&1 || true
        sudo -n systemctl stop "$service" || true
        sudo -n systemctl reset-failed "$service" >/dev/null 2>&1 || true
        sudo -n rm -f -- "$unit_dir/$timer" "$unit_dir/$service"
        sudo -n systemctl daemon-reload
        sudo -n rm -rf -- "$install_dir"
    fi
    if [[ -n $process_pid ]]; then
        kill "$process_pid" 2>/dev/null || true
        wait "$process_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

wait_for_report() {
    local pattern=$1 deadline=$((SECONDS + $2))
    while true; do
        sudo -n journalctl -b -u "$service" --after-cursor "$journal_cursor" \
            --no-pager -o cat > "$test_dir/report.log"
        if grep -E "$pattern" "$test_dir/report.log"; then
            return
        fi
        if (( SECONDS >= deadline )); then
            printf 'Timed out waiting for the health report matching %s\n' "$pattern" >&2
            return 1
        fi
        sleep 1
    done
}

install_dir=$(sudo -n mktemp -d /run/azure-infra-health-test.XXXXXXXX)
printf '[lab]\nlocalhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3\n' > "$test_dir/lab.ini"
disk_path="$install_dir/disk space %n \$HOME"
sudo -n mkdir -- "$disk_path"
python3 - "$disk_path" > "$test_dir/health.json" <<'PY'
import json
import sys

print(json.dumps({
    "lab_health_disk_path": sys.argv[1],
    "lab_health_process": "lab-mon-probe",
}))
PY
ln -s /usr/bin/sleep "$test_dir/lab-mon-probe"
"$test_dir/lab-mon-probe" 600 &
process_pid=$!
deadline=$((SECONDS + 5))
until [[ $(< "/proc/$process_pid/comm") == lab-mon-probe ]]; do
    (( SECONDS < deadline )) || { printf 'Test process did not start\n' >&2; exit 1; }
    sleep 0.1
done
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default
playbook=(ansible-playbook -i "$test_dir/lab.ini" ansible/install-tools.yml
    -e "lab_install_dir=$install_dir" -e lab_configure_health_timer=true
    -e "@$test_dir/health.json")

for invalid_settings in \
    '{"lab_health_process":"invalid/name"}' \
    '{"lab_health_process":"sleep\n"}' \
    '{"lab_health_disk_path":"relative/path"}' \
    '{"lab_health_disk_path":"/var\n[Unit]"}'; do
    printf '%s\n' "$invalid_settings" > "$test_dir/invalid.json"
    if "${playbook[@]}" -e "@$test_dir/invalid.json" > "$test_dir/invalid.log" 2>&1; then
        printf 'The playbook accepted invalid monitoring settings\n' >&2
        exit 1
    fi
    grep -q 'Use an absolute disk path' "$test_dir/invalid.log"
    test ! -e "$unit_dir/$service"
    test ! -e "$install_dir/scripts"
done
printf 'PASS: Invalid monitoring settings were rejected before installing units\n'

journal_cursor=$(sudo -n journalctl -n 0 --show-cursor -o cat | sed -n 's/^-- cursor: //p')
"${playbook[@]}"
systemd-analyze verify "$unit_dir/$service" "$unit_dir/$timer"
systemctl is-enabled --quiet "$timer"
systemctl is-active --quiet "$timer"

wait_for_report "$complete_report" 75
grep -qx 'process_name=lab-mon-probe' "$test_dir/report.log"
grep -qx 'process_state=present' "$test_dir/report.log"
sudo -n journalctl -b -u "$service" --since "$started" --no-pager -o json \
    --grep "$complete_report" | python3 -c '
import json
import sys

entries = [json.loads(line) for line in sys.stdin]
if not entries or any(int(entry["_UID"]) == 0 for entry in entries):
    sys.exit("Expected health reports from an unprivileged user")
'
printf 'PASS: The timer published a health report from an unprivileged user\n'

"${playbook[@]}" | tee "$test_dir/recheck.log"
grep -Eq '^localhost[[:space:]]*:[[:space:]]+ok=[1-9][0-9]*[[:space:]]+changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$test_dir/recheck.log"
printf 'PASS: Reapplying the playbook with monitoring enabled reported changed=0\n'

kill "$process_pid"
wait "$process_pid" 2>/dev/null || true
process_pid=''
sudo -n systemctl stop "$service"
journal_cursor=$(sudo -n journalctl -n 0 --show-cursor -o cat | sed -n 's/^-- cursor: //p')
sudo -n systemctl start "$service"
wait_for_report '^status=CRITICAL$' 10
grep -qx 'process_state=missing' "$test_dir/report.log"
test "$(systemctl show --property=ExecMainStatus --value "$service")" = 2
test "$(systemctl show --property=Result --value "$service")" = success
printf 'PASS: A missing required process produced CRITICAL without failing the systemd unit\n'

"$test_dir/lab-mon-probe" 600 &
process_pid=$!
sudo -n rm -- "$install_dir/scripts/lib/metrics.sh"
sudo -n systemctl stop "$service"
journal_cursor=$(sudo -n journalctl -n 0 --show-cursor -o cat | sed -n 's/^-- cursor: //p')
if sudo -n systemctl start "$service"; then
    printf 'The unit succeeded with its metrics library missing\n' >&2
    exit 1
fi
wait_for_report '^status=UNKNOWN$' 10
test "$(systemctl show --property=ExecMainStatus --value "$service")" = 3
test "$(systemctl show --property=Result --value "$service")" = exit-code
printf 'PASS: A missing metrics library produced UNKNOWN and a failed systemd unit\n'

journal_cursor=$(sudo -n journalctl -n 0 --show-cursor -o cat | sed -n 's/^-- cursor: //p')
"${playbook[@]}"
cmp scripts/lib/metrics.sh "$install_dir/scripts/lib/metrics.sh"
wait_for_report "$complete_report" 75
grep -qx 'process_state=present' "$test_dir/report.log"
test "$(systemctl show --property=Result --value "$service")" = success
systemctl is-active --quiet "$timer"
printf 'PASS: Ansible repaired the collector and the timer resumed successful checks\n'

"${playbook[@]}" | tee "$test_dir/recovered.log"
grep -Eq '^localhost[[:space:]]*:[[:space:]]+ok=[1-9][0-9]*[[:space:]]+changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$test_dir/recovered.log"
printf 'PASS: The recovered monitoring installation converged to changed=0\n'
