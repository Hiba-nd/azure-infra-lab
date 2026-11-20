# Linux health checks

`scripts/health-check.sh` collects a single report without changing system
configuration. It needs Linux, Bash 4+, awk, and GNU coreutils. Run `--help` for all
options. The prerequisite checker remains available as `scripts/check-environment.sh`.

```bash
bash scripts/health-check.sh --disk /var --process nginx \
  --cpu-warning 80 --cpu-critical 95 \
  --memory-warning 80 --memory-critical 90 \
  --disk-warning 80 --disk-critical 90
```

The process check is optional. The default disk path is `/`, the CPU sampling
interval is one second, and all default warning/critical thresholds are 80/90.
Thresholds are integers from 0 to 100; warning must be lower than critical.
`--interval` accepts 0.1..60 seconds, with up to three decimal places.

## Report and exit status

Stdout contains newline-delimited `key=value` fields: `timestamp_utc`,
`cpu_percent`, `cpu_status`, `memory_percent`, `memory_status`, `disk_percent`,
`disk_status`, and the overall `status`. Supplying `--process` adds `process_name`
and `process_state`. The timestamp uses the system clock in UTC.

| Code | Status | Meaning |
| --- | --- | --- |
| 0 | OK | All checked values are below warning thresholds |
| 1 | WARNING | At least one value is at or above warning |
| 2 | CRITICAL | At least one value is at or above critical, or the required process is missing |
| 3 | UNKNOWN | Invalid configuration, unreadable/malformed data, missing tools, or a collector failure |

Critical takes precedence over warning. Collection failures return 3, print only
`status=UNKNOWN` on stdout, and explain the failure on stderr. Threshold breaches
are normal monitoring results, not collection errors. `--help` exits 0 without
collecting data. The separate prerequisite checker uses its own documented 0/1/2
exit convention.

## Periodic sampling

`scripts/monitor-loop.sh` runs checks serially and publishes complete reports:

```bash
bash scripts/monitor-loop.sh --count 3 --delay 5 --timeout 10 -- --disk /var
```

Options after `--` are passed unchanged to the health checker. Defaults are an
unlimited sample count (`--count 0`), a 30-second delay, and a 10-second deadline
per check. The delay starts after a check finishes, so this is not a fixed
wall-clock schedule. Count accepts 0..999999, delay 0.1..3600 seconds, and timeout
an integer from 1 to 300 seconds. Choose a deadline that allows the CPU sampling
interval and filesystem query to finish.

Each report starts with `sample` and `sample_timestamp_utc` and ends with a blank
line. The runner buffers one report in a private temporary directory before
publishing it. A timeout, unexpected exit code, or disagreement between the
collector report and exit code produces UNKNOWN; partial results are discarded.
The timeout has a one-second forced-termination grace period.

The runner continues after warning, critical, and unknown results. A finite run
returns its worst observed status, even if a later check recovers. SIGINT/SIGTERM
stop its current check or delay, wait for the child, and remove temporary reports;
the runner exits 130/143 respectively. It does not restart services or modify
configuration. Separate invocations are independent; there is no global lock.

## systemd timer

On an Ubuntu host with systemd, enable scheduled checks with the same inventory
used to [install the lab tools](../README.md#install-on-an-ubuntu-host):

```bash
ansible-playbook -i /path/to/lab.ini ansible/install-tools.yml --limit lab-vm \
  -e lab_configure_health_timer=true
```

The timer starts `azure-infra-health.service` each minute. The service runs one
health check with its default thresholds. Set `lab_health_disk_path` to the
absolute path of a filesystem to check and `lab_health_process` to an optional
Linux process name. The defaults are `/` and an empty process name. For example,
add these variables to your inventory host:

```ini
lab-vm ansible_host=192.0.2.10 ansible_user=labadmin lab_health_disk_path=/var lab_health_process=sshd
```

Ansible validates the settings before changing the installation. The path must
be accessible to the service account. Home directories are hidden by the service
sandbox. Process names follow the health checker's 15-character limit. Arguments
containing spaces, literal dollar signs, and percent signs retain their values
when systemd executes the command.

The service uses a temporary unprivileged account, a private network namespace,
and a 15-second
startup deadline. Reports and diagnostics go to the system journal under the
host's retention policy.

```bash
systemctl list-timers azure-infra-health.timer
sudo journalctl -u azure-infra-health.service -n 30 --no-pager
sudo systemctl disable --now azure-infra-health.timer  # Stop scheduled checks
```

Systemd treats OK, WARNING, and CRITICAL as completed checks. Inspect `status=`
in the journal for the health result. UNKNOWN and timeouts fail the unit, and the
timer schedules the next check as usual. Alert delivery remains outside this lab.

## Failure and recovery test

`tests/test-systemd-monitoring.sh` runs on a disposable Ubuntu systemd host. It
creates a temporary installation and process, then exercises these cases:

| Scenario | Required result |
| --- | --- |
| Invalid name, relative path, or control characters | Ansible fails before changing the installation |
| Configured disk path and running process | Timer publishes a report from an unprivileged user |
| Required process is stopped | Report contains `process_state=missing` and `status=CRITICAL`, exit 2, unit result `success` |
| Metrics library is removed | Report contains `status=UNKNOWN`, exit 3, unit result `exit-code` |
| Ansible restores the library | The next scheduled check completes with the process present |
| Playbook is reapplied after repair | `changed=0` |

Journal cursors keep each assertion scoped to new reports. The test keeps the
timer running through the failures and repair. It waits for the next scheduled
report after repair and verifies that the service has recovered without manually
resetting its failed state. The temporary process, units, and installation are
removed on exit.

## Measurement semantics

- CPU: compare the first eight aggregate `/proc/stat` counters across the sampling
  interval. Subtract idle and iowait deltas from the total; guest counters are not
  added a second time. The result includes steal time as unavailable capacity.
  Zero progress or any counter decrease returns UNKNOWN, including a decreasing
  iowait counter. CPU hotplug and accounting changes can invalidate a sample.
- Memory: `100 * (MemTotal - MemAvailable) / MemTotal`. This estimates pressure
  rather than counting reclaimable page cache as fully occupied application memory.
  Both fields must occur exactly once, use kB, and satisfy `0 <= available <= total`.
- Disk: GNU `df --output=pcent -- PATH`, with a five-second timeout and a one-second
  forced-termination grace period. This is filesystem block usage, not inode usage
  or I/O latency. A value above 100 is critical, not discarded as malformed.
- Process: exact `/proc/PID/comm` matching in the visible PID namespace. Names are
  limited to 15 ASCII characters. Zombies and dead processes do not count. Presence
  does not establish readiness: a stopped or blocked process can still be present.

CPU and memory percentages are rounded to two decimal places before threshold
comparison. Disk uses the integer percentage reported by df. Threshold comparisons
are inclusive. This is a sample, not a sustained-load or availability guarantee.

The formulas follow the [kernel proc documentation](https://docs.kernel.org/filesystems/proc.html)
and [proc_stat(5)](https://man7.org/linux/man-pages/man5/proc_stat.5.html).

## Verification and scope

```text
docker compose run --rm --no-deps lab bash tests/run.sh --lab
docker compose run --rm --no-deps lab bash scripts/health-check.sh --disk /tmp --interval 0.1
```

Tests use synthetic counter/memory/process files for deterministic calculations
and failure cases, then collect real Linux data through the CLI. Synthetic inputs
are confined to tests; the CLI always reads live `/proc` data. A live test accepts
OK, WARNING, or CRITICAL as long as the report and exit status agree.
Sampler tests include a controlled CRITICAL-to-OK collector sequence, rejection
of inconsistent reports, a real check timeout, and SIGTERM during both a sampling
wait and the delay between samples. They verify descendant processes exit and
temporary reports are removed.
The delay-shutdown test deliberately slows a valid collection to six seconds.
Its readiness budget exceeds the runner's ten-second check deadline and grace
period; it still requires a completed report, a live direct sleep child, exit 143,
child termination, and temporary-file cleanup. Child discovery matches `Name` and
`PPid` in `/proc/PID/status`, avoiding the optional, race-prone
[`children` interface](https://man7.org/linux/man-pages/man5/proc_tid_children.5.html).

In Docker, CPU and memory can describe Docker's host kernel while process visibility
and filesystem mounts are container-specific. These metrics do not account for
cgroup quotas and are not a container utilization exporter. Run on a Linux VM to
observe that VM. The pinned Ubuntu lab covers collection and runner behavior.
GitHub Actions tests the timer in the Ubuntu runner's systemd manager. RHEL and
collection on an Azure VM remain unverified.
