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

## Continuous integration

The Linux CI workflow validates Compose and runs the same lab tests on pushes to
`main` and pull requests targeting it. The Ubuntu runner pulls the image pinned
in `compose.yaml`. The checkout uses a read-only repository token and clears its
credentials before the test steps.

## Limits

Git Bash on Windows is not Linux. The container shares Docker's Linux kernel;
`/proc` data can describe the Docker host rather than container resource limits.
It does not validate SSH, systemd, VM boot, or Azure behavior. No cloud resources
or deployment workflows are configured.
