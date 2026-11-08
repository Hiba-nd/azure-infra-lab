#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077
unset TAR_OPTIONS GZIP

usage() {
    printf '%s\n' 'Usage:
  bash scripts/backup-directory.sh create SOURCE BACKUP_ROOT
  bash scripts/backup-directory.sh verify BACKUP_DIRECTORY
  bash scripts/backup-directory.sh --help
SOURCE and BACKUP_ROOT must be existing directories. BACKUP_ROOT must be outside
SOURCE, owned by the current user, and not writable by group or others.
Exit codes: 0 success, 1 operation/verification failure, 2 invalid invocation.'
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
invalid() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

(( $# > 0 )) || invalid 'a subcommand is required; use --help'
if [[ $1 == --help && $# == 1 ]]; then usage; exit 0; fi
operation=$1
shift
case $operation in
    create) (( $# == 2 )) || invalid 'create requires SOURCE and BACKUP_ROOT' ;;
    verify) (( $# == 1 )) || invalid 'verify requires BACKUP_DIRECTORY' ;;
    *) invalid "unknown subcommand: $operation" ;;
esac
for path in "$@"; do
    [[ -n $path && $path != *$'\n'* && $path != *$'\r'* ]] || invalid 'paths must be nonempty and contain no line breaks'
done
for tool in uname realpath stat id tar gzip sha256sum date mktemp rm rmdir mv find; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done
[[ $(uname -s) == Linux ]] || die 'Linux is required'

check_directory() {
    local directory=$1 mode owner
    [[ -d $directory && -r $directory && -x $directory ]] || die 'backup directory is not accessible'
    owner=$(stat --format=%u -- "$directory") || die 'cannot read directory owner'
    mode=$(stat --format=%a -- "$directory") || die 'cannot read directory permissions'
    [[ $owner == "$(id -u)" ]] || die 'backup directory must be owned by the current user'
    [[ $mode =~ ^[0-7]{3,4}$ ]] || die 'cannot interpret directory permissions'
    (( (8#$mode & 0022) == 0 )) || die 'backup directory must not be writable by group or others'
}

verify_backup() {
    local directory=$1 record expected actual file
    local pattern='^([0-9a-f]{64})  archive[.]tar[.]gz$'
    check_directory "$directory"
    for file in archive.tar.gz archive.sha256; do
        [[ -f $directory/$file && ! -L $directory/$file ]] || die 'backup requires regular archive.tar.gz and archive.sha256 files'
    done
    record=$(< "$directory/archive.sha256")
    [[ $record =~ $pattern ]] || die 'checksum must name only archive.tar.gz with one SHA-256 digest'
    expected=${BASH_REMATCH[1]}
    actual=$(sha256sum < "$directory/archive.tar.gz") || die 'cannot read backup archive'
    [[ ${actual%% *} == "$expected" ]] || die 'backup checksum mismatch'
    tar --list --gzip --file "$directory/archive.tar.gz" >/dev/null || die 'backup is not a readable gzip tar archive'
}

if [[ $operation == verify ]]; then
    backup_directory=$(realpath --canonicalize-existing -- "$1") || die 'backup directory does not exist'
    verify_backup "$backup_directory"
    printf 'status=ok\n'
    exit 0
fi

source_directory=$(realpath --canonicalize-existing -- "$1") || die 'source directory does not exist'
backup_root=$(realpath --canonicalize-existing -- "$2") || die 'backup root does not exist'
[[ -d $source_directory && -r $source_directory && -x $source_directory ]] || die 'source must be an accessible directory'
check_directory "$backup_root"
[[ -w $backup_root ]] || die 'backup root is not writable'
[[ $backup_root != "$source_directory" && $backup_root != "${source_directory%/}/"* ]] \
    || die 'backup root must be outside the source directory'
unsupported=$(find -P "$source_directory" ! -type f ! -type d ! -type l -print -quit) \
    || die 'cannot inspect the source directory'
[[ -z $unsupported ]] || die 'source contains a special file; only regular files, directories, and symlinks are supported'

staging=''
cleanup() {
    if [[ -n $staging ]]; then
        rm -f -- "$staging/archive.tar.gz" "$staging/archive.sha256"
        rmdir -- "$staging"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
staging=$(mktemp -d -- "$backup_root/.backup.XXXXXXXX") || die 'cannot create staging directory'
tar --create --gzip --file "$staging/archive.tar.gz" --directory "$source_directory" -- . \
    || die 'archive creation failed; no backup was published'
digest=$(sha256sum < "$staging/archive.tar.gz") || die 'cannot checksum the archive'
printf '%s  archive.tar.gz\n' "${digest%% *}" > "$staging/archive.sha256"
verify_backup "$staging"
timestamp=$(date -u '+%Y%m%dT%H%M%SZ') || die 'cannot read the system clock'
destination="$backup_root/backup-$timestamp-${staging##*.}"
mv --no-clobber --no-target-directory -- "$staging" "$destination" || die 'cannot publish backup'
[[ ! -e $staging ]] || die 'backup name already exists; no existing backup was overwritten'
staging=''
printf 'backup_dir=%s\n' "$destination"
