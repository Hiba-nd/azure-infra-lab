# azure-infra-lab

Linux operations tools with an isolated Ubuntu test environment. The current
prerequisite checker verifies Bash, required utilities, readable `/proc` data,
and temporary-file access. It does not change host configuration.

## Run

On Linux:

```bash
bash scripts/check-environment.sh
bash tests/run.sh
```

For the isolated lab, use an existing Docker Linux engine, Docker Compose v2 or
newer, and the image pinned in `compose.yaml`:

```text
docker compose config --quiet
docker compose run --rm --no-deps lab
docker compose run --rm --no-deps lab bash tests/run.sh --lab
```

Compose will not download images automatically. After approving the download,
populate the cache with `docker compose pull --policy always lab`.

The lab uses UID 1000, read-only script/test mounts, a read-only root filesystem,
no network, no Linux capabilities, and a writable temporary filesystem. Each
container is removed after the command finishes. Tests cover successful checks,
error exits, cleanup, and these runtime restrictions.

The prerequisite checker returns 0 on success, 1 on a failed check, and 2 for
invalid arguments. Diagnostics go to stderr. `--help` describes its invocation.

## Limits

Git Bash on Windows is not Linux. The container shares Docker's Linux kernel;
`/proc` data can describe the Docker host rather than container resource limits.
It does not validate SSH, systemd, VM boot, or Azure behavior. No cloud resources
or deployment workflows are configured.
