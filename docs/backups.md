# Directory backups

`scripts/backup-directory.sh` creates, verifies, and restores gzip-compressed tar backups of
regular files, directories, and symlinks. It requires Linux, Bash, GNU tar, gzip,
GNU coreutils, and find. It runs with the current user's permissions.

```bash
mkdir -m 700 /path/to/backup-root
bash scripts/backup-directory.sh create /path/to/source /path/to/backup-root
bash scripts/backup-directory.sh verify /path/to/backup-root/backup-TIMESTAMP-SUFFIX
```

`create` prints one `backup_dir=ABSOLUTE_PATH` record on success. `verify` prints
`status=ok`. Commands return 0 on success, 1 on an operation or verification failure,
and 2 for an invalid invocation. Diagnostics go to stderr. Use an existing backup
root owned by the current user with group and other writes disabled. Its canonical
path must be outside the source tree. Use a trusted backup root outside the checkout
or under ignored `backups/` storage.

## Scheduled backups

On an Ubuntu host with systemd, run the backup playbook with the source directory
you want to protect. It imports the existing tool installer, creates the
`azure-lab-backup` system account with a non-login shell, and enables the timer.

```bash
ansible-playbook -i /path/to/lab.ini ansible/schedule-backups.yml --limit lab-vm \
  -e lab_backup_source=/srv/lab-data
```

The source must already exist and grant the backup account read access to files
and search access to directories. Grant access for the specific source through
its existing group or ACL configuration. Home directories are hidden and the
service has private temporary directories, so use a source visible in its sandbox,
such as `/srv/lab-data`.

| Setting | Default | Purpose |
| --- | --- | --- |
| `lab_backup_source` | Required | Existing source directory |
| `lab_backup_root` | `/var/lib/azure-infra-lab/backups` | Storage owned by the backup account, mode `0700` |
| `lab_backup_on_calendar` | `daily` | Systemd calendar expression, using the host timezone |

The playbook validates the schedule and resolves both paths to keep backups
outside the source tree. The service uses the same create and verify operations
as the CLI. It runs with an empty capability set, privilege escalation disabled,
a private network namespace, and a five-minute deadline. Its filesystem is
mounted read-only with write access granted to the backup directory and private
temporary storage. Reports and errors go to the system journal.

```bash
systemctl list-timers azure-infra-backup.timer
sudo journalctl -u azure-infra-backup.service -n 30 --no-pager
sudo systemctl start azure-infra-backup.service  # Run an additional backup
sudo systemctl disable --now azure-infra-backup.timer  # Stop the schedule
```

The persistent timer catches a missed run when it becomes active again. Existing
backups remain until an operator removes them. This storage is local to the host
and needs free space for subsequent archives.

Each backup is a directory containing:

```text
archive.tar.gz
archive.sha256
```

The checksum file contains one standard SHA-256 record naming `archive.tar.gz`.
Verification accepts only that filename, rejects symlinked bundle files, compares
the digest, and checks that GNU tar can read the archive. Checksums detect
accidental corruption; they do not authenticate a backup or encrypt its contents.

Creation uses a private hidden staging directory under the backup root. Archives
and checksum files are mode 600; published directories are mode 700. A nonzero tar
result, including an unreadable file or a detected source change, aborts creation
and removes staging files. Special files such as sockets, devices, and FIFOs are
rejected during source inspection. Symlinks within the source are stored as links,
not followed. Inherited `TAR_OPTIONS` and `GZIP` settings are ignored.

After archive verification, the directory is renamed within the same backup root
to a UTC timestamp plus a random suffix. Existing backups are not overwritten.
Directory publication prevents a partially written bundle appearing under its
final name; it is not a power-loss durability guarantee. The same-filesystem
operation follows [rename semantics](https://man7.org/linux/man-pages/man2/rename.2.html).

## Restore and scope

Use `restore` with a trusted backup and a new destination under a directory you
own. The destination parent must be writable by your user and protected against
group and other writes.

```bash
bash scripts/backup-directory.sh restore /path/to/backup /path/to/new-restore
```

For scheduled backups, run verification and restore as `azure-lab-backup` so that
the owner checks match. Prepare a private restore parent for that account, then
choose a new child directory:

```bash
sudo install -d -o azure-lab-backup -g azure-lab-backup -m 0700 /var/lib/azure-infra-lab/restores
sudo -u azure-lab-backup bash /opt/azure-infra-lab/scripts/backup-directory.sh \
  restore /var/lib/azure-infra-lab/backups/backup-TIMESTAMP-SUFFIX \
  /var/lib/azure-infra-lab/restores/recovered
```

Restore verifies a private copy of the archive, extracts it using the current
user and a private umask, and publishes the directory with a same-filesystem
rename. It prints `restore_dir=ABSOLUTE_PATH` on success. Choose an unused path.
If another process creates the destination during extraction, restore preserves it
and discards staging. Allow space for both the compressed copy and restored files.

The tests compare restored text and binary contents, hidden files, empty
directories, and symlinks. They also exercise corrupt archives, destination
collisions, and a simulated extraction failure after partial data was written.
Creation tests cover private permissions, unsafe paths, special files, and
cleanup after an unreadable-file failure.
Run the permission tests as a regular user; the Compose lab already does this.

GitHub Actions also runs `tests/test-scheduled-backup.sh` on a disposable Ubuntu
systemd host. A ten-second test schedule exercises a real timer activation. The
test verifies the archive under the backup account, restores and compares the
files and symlink, then makes a source file unreadable. It requires the failed
run to leave the published backup set unchanged. Restoring read access must
allow the timer to publish a new verified backup. The final Ansible run must
report `changed=0`. The test removes its account, units, timer state, and data.

The source should be quiescent while copying. Tar detecting some concurrent
changes does not provide a transactional snapshot or application/database
consistency. ACLs, extended attributes, encryption, retention, and off-host storage
are not managed. Backups under Docker's temporary filesystem disappear with the
container; those are test data, not persistent protection.
