# azure-infra-lab

Linux monitoring tools with an isolated Ubuntu test environment. The health checker
reports CPU, memory, filesystem usage, and optional process presence with configurable
thresholds and explicit failure statuses. A periodic runner adds bounded check
execution and shutdown cleanup. Neither command changes host configuration.
The directory backup command creates private, versioned archives with checksum
verification and publishes them only after verification succeeds.

## Run

On Linux:

```bash
bash scripts/check-environment.sh
bash scripts/health-check.sh --disk /var --process nginx
bash scripts/monitor-loop.sh --count 3 --delay 5 -- --disk /var
bash tests/run.sh
```

For the isolated lab, use an existing Docker Linux engine, Docker Compose v2 or
newer, and the image pinned in `compose.yaml`:

```text
docker compose config --quiet
docker compose run --rm --no-deps lab bash scripts/health-check.sh --disk /tmp
docker compose run --rm --no-deps lab bash tests/run.sh --lab
```

Compose will not download images automatically. After approving the download,
populate the cache with `docker compose pull --policy always lab`.

The lab uses UID 1000, read-only script/test mounts, a read-only root filesystem,
no network, no Linux capabilities, and a writable temporary filesystem. Each
container is removed after the command finishes. Tests cover successful checks,
error exits, cleanup, and these runtime restrictions.

The health checker returns 0 (OK), 1 (WARNING), 2 (CRITICAL), or 3 (UNKNOWN).
The prerequisite checker returns 0 on success, 1 on a failed check, and 2 for
invalid arguments. Diagnostics go to stderr. Each command supports `--help`.
See [monitoring behavior and limitations](docs/monitoring.md) for measurement
semantics, options, and test coverage.
See [directory backups](docs/backups.md) for creation, verification, restore, and
consistency limits.

## Install on an Ubuntu host

Run the playbook from a Linux machine with Ansible. The Ubuntu host needs
Python 3, SSH access, and an account that can use sudo. Create an inventory on
your controller with the `lab` group and substitute your host and username.

```ini
[lab]
lab-vm ansible_host=192.0.2.10 ansible_user=ubuntu
```

```bash
ansible-playbook -i /path/to/lab.ini ansible/install-tools.yml --limit lab-vm
```

Add `--ask-become-pass` if sudo prompts for a password. The playbook installs
the scripts and their libraries under `/opt/azure-infra-lab/scripts` with root
ownership. Run `/opt/azure-infra-lab/scripts/check-environment.sh` on the host to
check the installation. A second playbook run should report `changed=0`.

## Continuous integration

The Linux CI workflow validates Compose and runs the same lab tests on pushes to
`main` and pull requests targeting it. The Ubuntu runner pulls the image pinned
in `compose.yaml`. The checkout uses a read-only repository token and clears its
credentials before the test steps.
The Ansible test connects over SSH to a temporary server bound to the Ubuntu
runner's loopback address. It checks the installed files, changes the mode of
`check-environment.sh` from `0755` to `0644`, and verifies that the playbook
restores `0755`. The final run must report `changed=0`.

## Limits

Git Bash on Windows is not Linux. The container shares Docker's Linux kernel;
`/proc` data can describe the Docker host rather than container resource limits.
The SSH test covers deployment and permission repair on the runner. Testing on
a separate Ubuntu host and validating systemd, VM boot, and Azure are future work.
