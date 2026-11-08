#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
backup=("$BASH" "$repo_root/scripts/backup-directory.sh")
passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; if [[ -s $test_dir/stderr ]]; then cat "$test_dir/stderr" >&2; fi; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
expect_code() {
    local expected=$1 status=0
    shift
    "$@" > "$test_dir/stdout" 2> "$test_dir/stderr" || status=$?
    [[ $status == "$expected" ]] || fail "expected exit $expected, got $status: $*"
    pass "exit $expected: $*"
}
source_dir="$test_dir/source data"
backup_root="$test_dir/backup store"
restore_dir="$test_dir/restored data"
mkdir -p "$source_dir/config data" "$source_dir/empty" "$backup_root" "$restore_dir"
printf 'port=8080\n' > "$source_dir/config data/app.conf"
printf 'A\0B\n' > "$source_dir/binary.dat"
printf 'hidden\n' > "$source_dir/.hidden"
printf 'outside\n' > "$test_dir/outside.txt"
ln -s ../outside.txt "$source_dir/link"

PATH=/nonexistent expect_code 0 "${backup[@]}" --help
expect_code 2 "${backup[@]}"
expect_code 2 "${backup[@]}" create "$source_dir"
expect_code 2 "${backup[@]}" delete "$backup_root"
PATH=/nonexistent expect_code 1 "${backup[@]}" verify "$backup_root"

TAR_OPTIONS=--dereference expect_code 0 "${backup[@]}" create "$source_dir" "$backup_root"
[[ ! -s $test_dir/stderr ]] || fail 'unexpected backup creation diagnostic'
record=$(< "$test_dir/stdout")
[[ $record == backup_dir=* ]] || fail 'backup path missing from report'
created=${record#backup_dir=}
[[ -d $created && $created == "$backup_root/backup-"* ]] || fail 'backup was not published in the selected root'
[[ $(stat --format=%a -- "$created") == 700 ]] || fail 'backup directory must be private'
for file in archive.tar.gz archive.sha256; do
    [[ $(stat --format=%a -- "$created/$file") == 600 ]] || fail "backup file permissions: $file"
done
pass 'successful publication uses private directories and files'
expect_code 0 "${backup[@]}" verify "$created"
grep -qx 'status=ok' "$test_dir/stdout" || fail 'verification result missing'

tar --extract --gzip --file "$created/archive.tar.gz" --directory "$restore_dir"
for file in 'config data/app.conf' binary.dat .hidden; do
    cmp -- "$source_dir/$file" "$restore_dir/$file" || fail "restore changed file contents: $file"
done
[[ -d $restore_dir/empty ]] || fail 'empty directory did not survive restore'
[[ -L $restore_dir/link && $(readlink -- "$restore_dir/link") == ../outside.txt ]] || fail 'symlink was dereferenced or lost'
pass 'real restore preserves binary/text contents, hidden files, empty directories, and symlinks'

first_digest=$(sha256sum < "$created/archive.tar.gz")
expect_code 0 "${backup[@]}" create "$source_dir" "$backup_root"
second_record=$(< "$test_dir/stdout")
[[ ${second_record#backup_dir=} != "$created" ]] || fail 'backup name reused'
[[ $(sha256sum < "$created/archive.tar.gz") == "$first_digest" ]] || fail 'existing backup was modified'
pass 'successive backups do not overwrite previous archives'

mkdir -p "$source_dir/nested-output" "$test_dir/shared" "$test_dir/corrupt" "$test_dir/malformed" "$test_dir/linked" "$test_dir/bad-manifest"
expect_code 1 "${backup[@]}" create "$source_dir" "$source_dir/nested-output"
expect_code 1 "${backup[@]}" create "$source_dir" "$source_dir"
expect_code 1 "${backup[@]}" create "$test_dir/absent" "$backup_root"
chmod 777 "$test_dir/shared"
expect_code 1 "${backup[@]}" create "$source_dir" "$test_dir/shared"

cp -- "$created/archive.tar.gz" "$created/archive.sha256" "$test_dir/corrupt/"
printf 'damage' >> "$test_dir/corrupt/archive.tar.gz"
expect_code 1 "${backup[@]}" verify "$test_dir/corrupt"
[[ ! -s $test_dir/stdout ]] || fail 'corrupted archive must not report success'
grep -q 'checksum mismatch' "$test_dir/stderr" || fail 'checksum mismatch diagnostic missing'
pass 'archive corruption is detected before any restore'

printf 'not a tar archive\n' > "$test_dir/malformed/archive.tar.gz"
digest=$(sha256sum < "$test_dir/malformed/archive.tar.gz")
printf '%s  archive.tar.gz\n' "${digest%% *}" > "$test_dir/malformed/archive.sha256"
expect_code 1 "${backup[@]}" verify "$test_dir/malformed"
grep -q 'not a readable gzip tar archive' "$test_dir/stderr" || fail 'archive format diagnostic missing'
pass 'matching checksum alone does not establish archive readability'

cp -- "$created/archive.tar.gz" "$test_dir/bad-manifest/"
printf '%s  ../../outside.txt\n' "${first_digest%% *}" > "$test_dir/bad-manifest/archive.sha256"
expect_code 1 "${backup[@]}" verify "$test_dir/bad-manifest"
grep -q 'must name only archive.tar.gz' "$test_dir/stderr" || fail 'unsafe checksum record was accepted'
pass 'checksum records cannot select arbitrary filesystem paths'
ln -s "$created/archive.tar.gz" "$test_dir/linked/archive.tar.gz"
cp -- "$created/archive.sha256" "$test_dir/linked/"
expect_code 1 "${backup[@]}" verify "$test_dir/linked"
expect_code 1 "${backup[@]}" verify "$test_dir/absent"

mkfifo "$source_dir/channel"
expect_code 1 "${backup[@]}" create "$source_dir" "$backup_root"
grep -q 'source contains a special file' "$test_dir/stderr" || fail 'special file diagnostic missing'
rm -- "$source_dir/channel"
pass 'special files are rejected instead of silently omitted'

printf 'unreadable\n' > "$source_dir/unreadable"
chmod 000 "$source_dir/unreadable"
before=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | sort)
expect_code 1 "${backup[@]}" create "$source_dir" "$backup_root"
[[ ! -s $test_dir/stdout ]] || fail 'failed archive creation reported a backup path'
[[ $(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | sort) == "$before" ]] || fail 'failed backup left a partial or published directory'
pass 'a real unreadable-file failure cleans staging and publishes nothing'

printf '\n%d backup checks passed\n' "$passed"
