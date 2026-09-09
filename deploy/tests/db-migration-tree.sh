#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
safe_tmpdir() {
  local path="${TMPDIR:-$HOME/.acm-deploy-tests}" current mode
  if [ -z "${TMPDIR+x}" ]; then
    [ -d "$HOME" ] && [ ! -L "$HOME" ] || fail 'home directory is unsafe for retained fixtures'
    mkdir -m 0700 "$path" 2>/dev/null || true
  fi
  [ -d "$path" ] && [ ! -L "$path" ] || fail 'TMPDIR must be a real directory'
  path=$(CDPATH= cd -- "$path" && pwd -P)
  [ "$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")" = 700 ] || fail 'TMPDIR must be mode 0700'
  current="$path"
  while [ "$current" != / ]; do
    mode=$(stat -c '%a' "$current" 2>/dev/null || stat -f '%Lp' "$current")
    [ $((8#$mode & 0022)) -eq 0 ] || fail "TMPDIR has a writable ancestor: $current"
    [ ! -L "$current" ] || fail "TMPDIR has a symlink ancestor: $current"
    current=$(dirname -- "$current")
  done
  printf '%s\n' "$path"
}
TEST_TMPDIR=$(safe_tmpdir)

new_fixture() {
  FIXTURE=$(CDPATH= cd -- "$(mktemp -d "$TEST_TMPDIR/acm-db-migrations.XXXXXX")" && pwd -P)
  mkdir -p "$FIXTURE/repo/deploy" "$FIXTURE/repo/migrations/nested" "$FIXTURE/data" "$FIXTURE/backups"
  chmod 0750 "$FIXTURE/data"; chmod 0700 "$FIXTURE/backups"
  cp "$ROOT/deploy/acm-db.sh" "$FIXTURE/repo/deploy/acm-db.sh"
  printf 'services: {}\n' > "$FIXTURE/repo/compose.production.yml"
  printf 'ACM_DATA_DIR=%s/data\n' "$FIXTURE" > "$FIXTURE/repo/deploy/production.env"
  chmod 0600 "$FIXTURE/repo/deploy/production.env"
  printf 'select 1;\n' > "$FIXTURE/repo/migrations/nested/001.sql"
  printf 'database\n' > "$FIXTURE/data/db.sqlite"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/docker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/flock"
  chmod 0755 "$FIXTURE/docker" "$FIXTURE/flock" "$FIXTURE/repo/deploy/acm-db.sh"
  git -C "$FIXTURE/repo" init -q
  git -C "$FIXTURE/repo" config user.email test@example.invalid
  git -C "$FIXTURE/repo" config user.name test
  git -C "$FIXTURE/repo" add . && git -C "$FIXTURE/repo" commit -qm fixture
}

backup() {
  env ACM_DB_TEST_MODE=1 ACM_DATA_DIR="$FIXTURE/data" ACM_ENV_FILE="$FIXTURE/repo/deploy/production.env" ACM_DOCKER_BIN="$FIXTURE/docker" ACM_FLOCK_BIN="$FIXTURE/flock" ACM_DB_LOCK_PATH="$FIXTURE/db.lock" "$FIXTURE/repo/deploy/acm-db.sh" --repository-dir "$FIXTURE/repo" backup --backup-root "$FIXTURE/backups"
}

expect_rejected() {
  local label=$1 expected=$2 output status
  set +e; output=$(backup 2>&1); status=$?; set -e
  [ "$status" -ne 0 ] && [[ "$output" == *"$expected"* ]] || fail "$label was not rejected: $output"
  pass "$label"
}

new_fixture
backup >/dev/null || fail 'safe nested migration was rejected by DB helper'
pass 'safe nested migration is accepted by DB helper'

new_fixture
chmod 0770 "$FIXTURE/repo/migrations/nested"
expect_rejected 'group-writable nested migration directory' 'group- or world-writable'

new_fixture
chmod 0660 "$FIXTURE/repo/migrations/nested/001.sql"
expect_rejected 'group-writable nested migration file' 'group- or world-writable'

new_fixture
ln -s 001.sql "$FIXTURE/repo/migrations/nested/link.sql"
expect_rejected 'migration symlink' 'nonregular or symlink entry'

if command -v mkfifo >/dev/null 2>&1; then
  new_fixture
  mkfifo "$FIXTURE/repo/migrations/nested/pipe"
  expect_rejected 'migration special entry' 'nonregular or symlink entry'
fi
