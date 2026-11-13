#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"
test_user=$(id -un)
test_dir=$(mktemp -d "$HOME/.azure-infra-ssh.XXXXXXXX")
installed="$test_dir/installed"
port=22222

cleanup() {
    local status=$?
    if (( status != 0 )) && [[ -f $test_dir/sshd.log ]]; then
        cat "$test_dir/sshd.log" >&2
    fi
    if [[ -s $test_dir/sshd.pid ]]; then
        sudo -n kill -- "$(< "$test_dir/sshd.pid")" 2>/dev/null || true
    fi
    sudo -n rm -rf -- "$test_dir"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$test_dir/host"
ssh-keygen -q -t ed25519 -N '' -f "$test_dir/client"
printf '[127.0.0.1]:%s %s\n' "$port" "$(< "$test_dir/host.pub")" > "$test_dir/known_hosts"

cat > "$test_dir/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey "$test_dir/host"
PidFile "$test_dir/sshd.pid"
AuthorizedKeysFile "$test_dir/client.pub"
AllowUsers $test_user
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
DisableForwarding yes
UsePAM yes
Subsystem sftp internal-sftp
EOF

cat > "$test_dir/ssh_config" <<EOF
Host 127.0.0.1
    Port $port
    User $test_user
    IdentityFile "$test_dir/client"
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking yes
    UserKnownHostsFile "$test_dir/known_hosts"
    GlobalKnownHostsFile /dev/null
    ConnectTimeout 5
EOF

sudo -n mkdir -p /run/sshd
sudo -n /usr/sbin/sshd -t -f "$test_dir/sshd_config"
sudo -n /usr/sbin/sshd -f "$test_dir/sshd_config" -E "$test_dir/sshd.log"

printf '[lab]\nssh-lab ansible_host=127.0.0.1 ansible_connection=ssh ansible_python_interpreter=/usr/bin/python3\n' > "$test_dir/lab.ini"
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_ARGS="-F \"$test_dir/ssh_config\""
export ANSIBLE_SSH_TRANSFER_METHOD=sftp
playbook=(ansible-playbook -i "$test_dir/lab.ini" ansible/install-tools.yml -e "lab_install_dir=$installed")

"${playbook[@]}"
diff -r scripts/ "$installed/scripts/"
check_script="$installed/scripts/check-environment.sh"
test "$(stat -c '%U:%G:%a' "$check_script")" = root:root:755
ssh -F "$test_dir/ssh_config" 127.0.0.1 "bash '$check_script'"

sudo -n chmod 0644 -- "$check_script"
test "$(stat -c '%a' "$check_script")" = 644
"${playbook[@]}" | tee "$test_dir/repair.log"
test "$(stat -c '%U:%G:%a' "$check_script")" = root:root:755
grep -Eq '^ssh-lab[[:space:]]*:[[:space:]]+ok=[1-9][0-9]*[[:space:]]+changed=1[[:space:]]+unreachable=0[[:space:]]+failed=0' "$test_dir/repair.log"
printf 'PASS: Ansible restored the script mode from 0644 to 0755 over SSH\n'

"${playbook[@]}" | tee "$test_dir/recheck.log"
grep -Eq '^ssh-lab[[:space:]]*:[[:space:]]+ok=[1-9][0-9]*[[:space:]]+changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$test_dir/recheck.log"
printf 'PASS: Ansible reported changed=0 after repairing permissions\n'
