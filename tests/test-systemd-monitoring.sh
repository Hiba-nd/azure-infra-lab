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
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

install_dir=$(sudo -n mktemp -d /run/azure-infra-health-test.XXXXXXXX)
printf '[lab]\nlocalhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3\n' > "$test_dir/lab.ini"
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default
playbook=(ansible-playbook -i "$test_dir/lab.ini" ansible/install-tools.yml
    -e "lab_install_dir=$install_dir" -e lab_configure_health_timer=true)

"${playbook[@]}"
systemd-analyze verify "$unit_dir/$service" "$unit_dir/$timer"
systemctl is-enabled --quiet "$timer"
systemctl is-active --quiet "$timer"

deadline=$((SECONDS + 75))
until sudo -n journalctl -b -u "$service" --since "$started" --no-pager -o cat \
    | grep -E "$complete_report"; do
    if (( SECONDS >= deadline )); then
        printf 'Timed out waiting for the timer to publish a health report\n' >&2
        exit 1
    fi
    sleep 1
done
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
