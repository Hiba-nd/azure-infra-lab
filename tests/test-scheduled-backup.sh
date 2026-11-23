#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"
service=azure-infra-backup.service
timer=azure-infra-backup.timer
backup_user=azure-lab-backup
unit_dir=/etc/systemd/system
stamp=/var/lib/systemd/timers/stamp-azure-infra-backup.timer

for unit in "$service" "$timer"; do
    if [[ $(systemctl show --property=LoadState --value "$unit") != not-found ||
        -e $unit_dir/$unit || -L $unit_dir/$unit ]]; then
        printf 'Expected a disposable host without %s\n' "$unit" >&2
        exit 1
    fi
done
if getent passwd "$backup_user" || getent group "$backup_user" || sudo -n test -e "$stamp"; then
    printf 'The backup account and timer state must be absent before this test\n' >&2
    exit 1
fi

test_dir=$(mktemp -d)
runtime_dir=''
started="@$(date +%s)"
cleanup() {
    local status=$?
    if (( status != 0 )); then
        systemctl status --no-pager "$timer" "$service" >&2 || true
        sudo -n journalctl -b -u "$service" --since "$started" --no-pager >&2 || true
    fi
    if [[ -n $runtime_dir ]]; then
        sudo -n systemctl disable --now "$timer" >/dev/null 2>&1 || true
        sudo -n systemctl stop "$service" || true
        sudo -n systemctl reset-failed "$service" >/dev/null 2>&1 || true
        sudo -n rm -f -- "$unit_dir/$timer" "$unit_dir/$service" "$stamp"
        sudo -n systemctl daemon-reload
        sudo -n rm -rf -- "$runtime_dir"
        if getent passwd "$backup_user" >/dev/null; then sudo -n userdel "$backup_user"; fi
        if getent group "$backup_user" >/dev/null; then sudo -n groupdel "$backup_user"; fi
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

wait_for_backup() {
    local deadline=$((SECONDS + 35))
    while true; do
        sudo -n journalctl -b -u "$service" --after-cursor "$journal_cursor" \
            --no-pager -o cat > "$test_dir/backup.log"
        backup_dir=$(sed -n 's/^backup_dir=//p' "$test_dir/backup.log" | tail -n 1)
        if [[ -n $backup_dir ]]; then return; fi
        if (( SECONDS >= deadline )); then
            printf 'Timed out waiting for a scheduled verified backup\n' >&2
            return 1
        fi
        sleep 1
    done
}

runtime_dir=$(sudo -n mktemp -d /run/azure-infra-backup-test.XXXXXXXX)
sudo -n chmod 0755 "$runtime_dir"
source_dir="$runtime_dir/source data %n \$HOME"
backup_root="$runtime_dir/backups %n \$HOME"
sudo -n mkdir -m 0755 -- "$source_dir"
printf 'port=8080\n' > "$test_dir/app.conf"
sudo -n install -m 0644 "$test_dir/app.conf" "$source_dir/app.conf"
sudo -n ln -s app.conf "$source_dir/current"
printf '[lab]\nlocalhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3\n' > "$test_dir/lab.ini"
python3 - "$runtime_dir/tools" "$source_dir" "$backup_root" "$test_dir" > "$test_dir/settings.json" <<'PY'
import json
import sys
from pathlib import Path

print(json.dumps({
    "lab_install_dir": sys.argv[1],
    "lab_backup_source": sys.argv[2],
    "lab_backup_root": sys.argv[3],
    "lab_backup_on_calendar": "*-*-* *:*:0/10",
}))
invalid_settings = {
    "nested-root": {"lab_backup_root": str(Path(sys.argv[2]) / "backups")},
    "invalid-schedule": {"lab_backup_on_calendar": "invalid schedule"},
}
for name, settings in invalid_settings.items():
    (Path(sys.argv[4]) / f"{name}.json").write_text(json.dumps(settings))
PY
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default
playbook=(ansible-playbook -i "$test_dir/lab.ini" ansible/schedule-backups.yml
    -e "@$test_dir/settings.json")
for invalid in nested-root invalid-schedule; do
    if "${playbook[@]}" -e "@$test_dir/$invalid.json" > "$test_dir/$invalid.log" 2>&1; then
        printf 'The playbook accepted invalid backup settings\n' >&2
        exit 1
    fi
    grep -Eq '^localhost[[:space:]]*:[[:space:]].*failed=1' "$test_dir/$invalid.log"
    if getent passwd "$backup_user" >/dev/null || sudo -n test -e "$backup_root"; then
        printf 'Invalid backup settings changed the backup account or storage\n' >&2
        exit 1
    fi
done
printf 'PASS: Nested storage and an invalid schedule were rejected before backup setup\n'

journal_cursor=$(sudo -n journalctl -n 0 --show-cursor -o cat | sed -n 's/^-- cursor: //p')
"${playbook[@]}"
systemd-analyze verify "$unit_dir/$service" "$unit_dir/$timer"
systemctl is-enabled --quiet "$timer"
systemctl is-active --quiet "$timer"
wait_for_backup
sudo -n systemctl stop "$timer" "$service"
test "$(sudo -n stat -c '%U:%a' "$backup_dir")" = "$backup_user:700"
test "$(sudo -n stat -c '%U:%a' "$backup_dir/archive.tar.gz")" = "$backup_user:600"
backup=(sudo -n -u "$backup_user" bash "$runtime_dir/tools/scripts/backup-directory.sh")
"${backup[@]}" verify "$backup_dir"
printf 'PASS: The timer published a verified backup owned by the unprivileged account\n'

restore_root="$runtime_dir/restores"
sudo -n install -d -o "$backup_user" -g "$backup_user" -m 0700 "$restore_root"
"${backup[@]}" restore "$backup_dir" "$restore_root/recovered"
sudo -n diff -r -- "$source_dir" "$restore_root/recovered"
test "$(sudo -n readlink "$restore_root/recovered/current")" = app.conf
printf 'PASS: The scheduled backup restored matching contents and a symlink\n'

previous_backup=$backup_dir
before=$(sudo -n find "$backup_root" -mindepth 1 -maxdepth 1 -type d | sort)
sudo -n chmod 000 "$source_dir/app.conf"
if sudo -n systemctl start "$service"; then
    printf 'The backup unit succeeded with an unreadable source file\n' >&2
    exit 1
fi
test "$(systemctl show --property=ExecMainStatus --value "$service")" = 1
test "$(systemctl show --property=Result --value "$service")" = exit-code
test "$(sudo -n find "$backup_root" -mindepth 1 -maxdepth 1 -type d | sort)" = "$before"
printf 'PASS: An unreadable source failed the unit without publishing a partial backup\n'

sudo -n chmod 0644 "$source_dir/app.conf"
journal_cursor=$(sudo -n journalctl -n 0 --show-cursor -o cat | sed -n 's/^-- cursor: //p')
"${playbook[@]}"
wait_for_backup
test "$backup_dir" != "$previous_backup"
"${backup[@]}" verify "$backup_dir"
printf 'PASS: Scheduled backups resumed after source access was restored\n'

"${playbook[@]}" | tee "$test_dir/recheck.log"
test "$(grep -Ec '^localhost[[:space:]]*:[[:space:]]+ok=[1-9][0-9]*[[:space:]]+changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$test_dir/recheck.log")" = 1
printf 'PASS: Reapplying the backup playbook reported changed=0\n'
