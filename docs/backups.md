# Directory backups

`scripts/backup-directory.sh` creates and verifies gzip-compressed tar backups of
regular files, directories, and symlinks. It requires Linux, Bash, GNU tar, gzip,
GNU coreutils, and find. It runs with the current user's permissions.

```bash
mkdir -m 700 /path/to/backup-root
bash scripts/backup-directory.sh create /path/to/source /path/to/backup-root
bash scripts/backup-directory.sh verify /path/to/backup-root/backup-TIMESTAMP-SUFFIX
```

`create` prints one `backup_dir=ABSOLUTE_PATH` record on success. `verify` prints
`status=ok`. Both return 0 on success, 1 on an operation or verification failure,
and 2 for an invalid invocation. Diagnostics go to stderr; failures do not print a
success record. The backup root must already exist, be owned by the current user,
and have no group/other write permission. Its canonical path must be outside the
source tree. Use a trusted backup root outside the checkout or under ignored
`backups/` storage.

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

Restore is an explicit GNU tar operation into a new empty directory. For a trusted,
successfully verified backup:

```bash
mkdir -m 700 /path/to/new-restore
tar --extract --gzip --file /path/to/backup/archive.tar.gz --directory /path/to/new-restore
```

The test suite performs this round trip and compares text, binary and hidden file
contents. It checks empty directories, symlinks, private permissions, unique backup
names, checksum corruption, malformed archives, unsafe paths, special files, and
cleanup after a real unreadable-file failure.
Run the permission tests as a regular user; the Compose lab already does this.

The source should be quiescent while copying. Tar detecting some concurrent
changes does not provide a transactional snapshot or application/database
consistency. ACLs, extended attributes, encryption, retention, and off-host storage
are not managed. Backups under Docker's temporary filesystem disappear with the
container; those are test data, not persistent protection.
