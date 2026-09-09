#!/usr/bin/env bash
# Dependency-free semantic tests for deployment helpers. Fixtures are retained
# under TMPDIR for inspection; this harness deliberately performs no cleanup.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
PASS=0; SKIP=0

pass() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'ok - %s # SKIP %s\n' "$1" "$2"; }
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
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
FIXTURE=$(CDPATH= cd -- "$(mktemp -d "$TEST_TMPDIR/acm-semantic.XXXXXX")" && pwd -P)
expect_fail() { local label=$1 needle=$2; shift 2; local out status; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" -ne 0 ] || fail "$label unexpectedly succeeded"; [[ "$out" == *"$needle"* ]] || fail "$label missing '$needle': $out"; pass "$label"; }
expect_ok() { local label=$1; shift; local out status; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" = 0 ] || fail "$label failed: $out"; pass "$label"; }
expect_status() { local label=$1 expected=$2; shift 2; local status; set +e; "$@" >/dev/null 2>&1; status=$?; set -e; [ "$status" = "$expected" ] || fail "$label returned $status, expected $expected"; pass "$label"; }
write() { mkdir -p "$(dirname -- "$1")"; printf '%b' "$2" > "$1"; }

make_repo() {
  local repo=$1
  mkdir -p "$repo/deploy" "$repo/migrations" "$repo/.local"
  cp "$ROOT/deploy/acm-deploy.sh" "$ROOT/deploy/acm-db.sh" "$repo/deploy/"
  write "$repo/deploy/smoke.sh" '#!/usr/bin/env bash
printf "%s\\n" smoke >> "${MOCK_SMOKE_LOG:-/dev/null}"
[ "${MOCK_SMOKE_MODE:-ok}" = fail ] && exit 7
exit 0
'
  chmod +x "$repo/deploy/smoke.sh"
  write "$repo/compose.production.yml" 'services: {}\n'
  write "$repo/deploy/.env.production" "ACM_DATA_DIR=$repo/data\nAPI_DOMAIN=api.example.test\n"
  chmod 600 "$repo/deploy/.env.production"
  write "$repo/migrations/001.sql" 'select 1;\n'
  git -C "$repo" init -q
  git -C "$repo" config user.email semantic@example.test
  git -C "$repo" config user.name semantic
  git -C "$repo" add . && git -C "$repo" commit -qm initial
}

make_git_mock() {
  local bin=$1 real=$2 log=$3
  write "$bin" '#!/usr/bin/env bash
printf "%s\\n" "$*" >> "${MOCK_LOG:?}"
exec "${GIT_REAL:?}" "$@"
'
  chmod +x "$bin"
}

make_docker() {
  local bin=$1 log=$2 mode=${3:-ok}
  write "$bin.mode" "$mode\n"
  write "$bin" '#!/usr/bin/env bash
mode=$(<"$0.mode")
printf "%s\\n" "$*" >> "${MOCK_LOG:-/dev/null}"
case "$mode" in
  hang) sleep 10 ;;
  health-fail) [ "${1:-}" = inspect ] && { printf "running unhealthy\\n"; exit 0; } ;;
  fail-build) for arg in "$@"; do [ "$arg" = build ] && exit 9; done ;;
  fail-up) for arg in "$@"; do [ "$arg" = up ] && exit 8; done ;;
esac
if [[ "$*" == *"ps -q"* ]]; then printf "container\\n"; fi
if [[ "${1:-}" = inspect ]]; then printf "running healthy\\n"; fi
'
  chmod +x "$bin"
}

bootstrap_tests() {
  local repo="$FIXTURE/bootstrap-repo" base="$FIXTURE/bootstrap-paths" out
  write "$FIXTURE/bootstrap-runner" '#!/usr/bin/env bash\n"$@"\n'; chmod +x "$FIXTURE/bootstrap-runner"
  make_repo "$repo"
  mkdir -p "$base/data" "$base/backup" "$base/quarantine"
  chmod 0750 "$base/data"
  chmod 0700 "$base/backup" "$base/quarantine"
  local run=(env ACM_BOOTSTRAP_TEST_MODE=1 ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE" ACM_BOOTSTRAP_TEST_RUNNER="$FIXTURE/bootstrap-runner" ACM_REPOSITORY_DIR="$repo" ACM_DATA_DIR="$base/data" ACM_BACKUP_DIR="$base/backup" ACM_QUARANTINE_DIR="$base/quarantine" "$ROOT/deploy/bootstrap-ubuntu.sh" --check)
  expect_fail 'bootstrap rejects protected root' 'protected system path' env ACM_BOOTSTRAP_TEST_MODE=1 ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE" ACM_BOOTSTRAP_TEST_RUNNER="$FIXTURE/bootstrap-runner" ACM_REPOSITORY_DIR="$repo" ACM_DATA_DIR=/usr/acm-test ACM_BACKUP_DIR="$base/backup" ACM_QUARANTINE_DIR="$base/quarantine" "$ROOT/deploy/bootstrap-ubuntu.sh" --check
  expect_fail 'bootstrap rejects broad root' 'broad system path' env ACM_BOOTSTRAP_TEST_MODE=1 ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE" ACM_BOOTSTRAP_TEST_RUNNER="$FIXTURE/bootstrap-runner" ACM_REPOSITORY_DIR="$repo" ACM_DATA_DIR=/opt ACM_BACKUP_DIR="$base/backup" ACM_QUARANTINE_DIR="$base/quarantine" "$ROOT/deploy/bootstrap-ubuntu.sh" --check
  expect_fail 'bootstrap rejects overlap' 'must not overlap' env ACM_BOOTSTRAP_TEST_MODE=1 ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE" ACM_BOOTSTRAP_TEST_RUNNER="$FIXTURE/bootstrap-runner" ACM_REPOSITORY_DIR="$repo" ACM_DATA_DIR="$base/data" ACM_BACKUP_DIR="$base/data/backup" ACM_QUARANTINE_DIR="$base/quarantine" "$ROOT/deploy/bootstrap-ubuntu.sh" --check
  expect_ok 'bootstrap accepts ordinary dedicated check-mode paths' "${run[@]}"
  out=$("${run[@]}" 2>&1)
  [[ "$out" != *'apt-get'* && "$out" != *'systemctl'* && "$out" != *'ufw'* ]] || fail 'bootstrap check attempted host mutation'
  pass 'bootstrap check performs no host mutation'
  write "$base/data/unmarked" x
  expect_fail 'bootstrap rejects unmarked nonempty directory' 'nonempty and unmarked' "${run[@]}"
  expect_ok 'bootstrap adopts reviewed nonempty directory' env ACM_BOOTSTRAP_TEST_MODE=1 ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE" ACM_BOOTSTRAP_TEST_RUNNER="$FIXTURE/bootstrap-runner" ACM_REPOSITORY_DIR="$repo" ACM_DATA_DIR="$base/data" ACM_BACKUP_DIR="$base/backup" ACM_QUARANTINE_DIR="$base/quarantine" "$ROOT/deploy/bootstrap-ubuntu.sh" --check --adopt-existing-paths
  write "$base/data/.acm-managed" 'acm-managed-v1:backup\n'
  expect_fail 'bootstrap rejects wrong marker role' 'wrong version or role' "${run[@]}"
}

db_tests() {
  local repo="$FIXTURE/db-repo" data="$FIXTURE/db-data" backups="$FIXTURE/backups" envfile="$FIXTURE/db.env" lock="$FIXTURE/db.lock" docker="$FIXTURE/docker-db" flockbin="$FIXTURE/flock" log="$FIXTURE/db.log" out backup quarantine fakebin
  make_repo "$repo"; mkdir -p "$data" "$backups"; chmod 0750 "$data"; chmod 0700 "$backups"; write "$data/db.sqlite" database
  make_docker "$docker" "$log"
  write "$flockbin" '#!/usr/bin/env bash\nexit 0\n'; chmod +x "$flockbin"
  out=$("$ROOT/deploy/acm-db.sh" --repository-dir "$FIXTURE/no-config" --help) || fail 'acm-db help required configuration'
  [[ "$out" == *'[--repository-dir ABSOLUTE_PATH] metadata'* ]] || fail 'acm-db help omits global repository option for metadata'
  pass 'acm-db help is configuration-free and documents global repository option'
  expect_fail 'acm-db rejects production override' 'override requires ACM_DB_TEST_MODE=1' env ACM_DATA_DIR="$data" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" backup --backup-root "$backups"
  for quote in plain single double; do
    case "$quote" in plain) value="$data";; single) value="'$data'";; double) value="\"$data\"";; esac
    write "$envfile" "ACM_DATA_DIR=$value\n"
    chmod 0600 "$envfile"
    expect_ok "acm-db accepts $quote literal data path" env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" backup --backup-root "$backups"
  done
  write "$envfile" "ACM_DATA_DIR=\$(touch $FIXTURE/dotenv-executed)\n"
  chmod 0600 "$envfile"
  expect_fail 'acm-db does not execute malicious dotenv' 'absolute, literal path' env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" verify --backup-dir "$backups"
  [ ! -e "$FIXTURE/dotenv-executed" ] || fail 'dotenv payload executed'
  pass 'acm-db leaves malicious dotenv inert'
  write "$envfile" "ACM_DATA_DIR=$data\nACM_DATA_DIR=$data\n"
  chmod 0600 "$envfile"
  expect_fail 'acm-db propagates duplicate data locator errors' 'duplicate ACM_DATA_DIR' env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" verify --backup-dir "$backups"
  write "$envfile" 'ACM_DATA_DIR=\n'
  chmod 0600 "$envfile"
  expect_fail 'acm-db propagates empty data locator errors' 'must be an absolute, literal path' env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" verify --backup-dir "$backups"
  write "$envfile" "ACM_DATA_DIR=$data\n"
  chmod 0600 "$envfile"
  out=$(env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" backup --backup-root "$backups")
  [[ "$out" =~ ^BACKUP_DIR=/ ]] || fail "backup stdout is not exact: $out"; backup=${out#BACKUP_DIR=}
  expect_ok 'acm-db emits valid backup metadata' env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" metadata --backup-dir "$backup"
  local default_quarantine="$FIXTURE/.acm-quarantine" data_filesystem parent_filesystem
  [ ! -e "$default_quarantine" ] || fail 'default dry-run quarantine fixture already exists'
  data_filesystem=$(stat -c '%d' "$data" 2>/dev/null || stat -f '%d' "$data")
  parent_filesystem=$(stat -c '%d' "$FIXTURE" 2>/dev/null || stat -f '%d' "$FIXTURE")
  [ "$data_filesystem" = "$parent_filesystem" ] || fail 'dry-run quarantine parent is not on the data filesystem'
  : > "$log"
  expect_ok 'acm-db dry-run accepts absent default quarantine without mutation' env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" restore --backup-dir "$backup" --yes-restore --dry-run
  [ ! -e "$default_quarantine" ] || fail 'dry-run created the default quarantine root'
  [ ! -s "$log" ] || fail 'dry-run invoked Docker'
  pass 'acm-db dry-run leaves absent default quarantine and Docker untouched'
  quarantine="$FIXTURE/db-quarantine"; mkdir -p "$quarantine"; chmod 0700 "$quarantine"; fakebin="$FIXTURE/db-bin"; mkdir -p "$fakebin"; write "$fakebin/chown" '#!/usr/bin/env bash\nexit 0\n'; chmod +x "$fakebin/chown"
  write "$data/db.sqlite-journal" stale; : > "$log"
  expect_ok 'acm-db restore quarantines regular stale journal' env PATH="$fakebin:$PATH" ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" restore --backup-dir "$backup" --quarantine-root "$quarantine" --yes-restore
  [ ! -e "$data/db.sqlite-journal" ] || fail 'restore left stale journal at destination'
  compgen -G "$quarantine/acm-quarantine-*/db.sqlite-journal" >/dev/null || fail 'restore did not quarantine stale journal'
  pass 'acm-db restore leaves no stale journal at destination'
  ln -s retained "$data/db.sqlite-journal"; : > "$log"
  expect_fail 'acm-db restore rejects symlink sidecar before mutation' 'symlink database sidecar rejected' env PATH="$fakebin:$PATH" ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" restore --backup-dir "$backup" --quarantine-root "$quarantine" --yes-restore
  [ -f "$data/db.sqlite" ] || fail 'symlink sidecar failure mutated source database'
  mv "$data/db.sqlite-journal" "$FIXTURE/retained-symlink-sidecar"
  mkdir "$data/db.sqlite-journal-dir"; : > "$log"
  expect_fail 'acm-db restore rejects nonregular sidecar before mutation' 'nonregular database sidecar rejected' env PATH="$fakebin:$PATH" ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" restore --backup-dir "$backup" --quarantine-root "$quarantine" --yes-restore
  [ -f "$data/db.sqlite" ] || fail 'nonregular sidecar failure mutated source database'
  mv "$data/db.sqlite-journal-dir" "$FIXTURE/retained-nonregular-sidecar"
  write "$fakebin/cp" '#!/usr/bin/env bash\nexit 9\n'; chmod +x "$fakebin/cp"; : > "$log"
  expect_fail 'acm-db restore copy failure is retained after stop' 'restore is incomplete; server remains stopped' env PATH="$fakebin:$PATH" ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" restore --backup-dir "$backup" --quarantine-root "$quarantine" --yes-restore
  pass 'acm-db restore failure leaves server stopped'
  chmod 0700 "$backup"; write "$backup/unexpected" x; chmod 0400 "$backup/unexpected"; chmod 0500 "$backup"
  expect_fail 'acm-db rejects unknown backup file' 'unknown backup file' env ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$envfile" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" verify --backup-dir "$backup"
  # Hold the shared global lock. Restore must fail at lock acquisition, before malformed backup verification.
  if command -v flock >/dev/null 2>&1; then
    (
      local holder='' actual='' control="$FIXTURE/db-flock-control" i
      mkdir -m 0700 "$control"
      bash "$ROOT/deploy/tests/support/lock-holder.sh" "$lock" "$control" flock & holder=$!
      trap '[ -z "$holder" ] || { kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; }' EXIT
      for i in $(seq 1 30); do [ -f "$control/ready" ] && break; kill -0 "$holder" 2>/dev/null || fail 'database lock holder exited before ready'; sleep 0.1; done
      [ -f "$control/ready" ] || fail 'database lock holder did not become ready'
      actual=$(<"$control/pid"); [[ "$actual" =~ ^[1-9][0-9]*$ ]] && kill -0 "$actual" 2>/dev/null || fail 'database lock holder PID is invalid'
      expect_fail 'acm-db restore locks before backup verification' 'another ACM database operation is active' env ACM_DB_TEST_MODE=1 ACM_DOCKER_BIN="$docker" ACM_DB_LOCK_PATH="$lock" "$ROOT/deploy/acm-db.sh" --repository-dir "$repo" restore --backup-dir "$backup" --yes-restore
      : > "$control/release"; for i in $(seq 1 30); do kill -0 "$actual" 2>/dev/null || break; sleep 0.1; done
      kill -0 "$actual" 2>/dev/null && fail 'database lock holder did not release'
      wait "$holder"; holder=''
      flock -n "$lock" true || fail 'database lock was not released after holder cleanup'
    )
    pass 'acm-db global lock contention is enforced'
  else
    skip 'acm-db lock contention' 'flock is unavailable on this host'
  fi
}

deploy_tests() {
  local repo="$FIXTURE/deploy-repo" data="$FIXTURE/deploy-data" state="$FIXTURE/state" lock="$FIXTURE/deploy.lock" docker="$FIXTURE/docker-deploy" flockbin="$FIXTURE/deploy-flock" log="$FIXTURE/deploy.log" gitbin="$FIXTURE/git" backuproot="$FIXTURE/deploy-backups" rev1 rev2 backup bad_backup real_git
  make_repo "$repo"; mkdir -p "$data" "$state" "$backuproot"; chmod 0750 "$data"; chmod 0700 "$state" "$backuproot"; write "$data/db.sqlite" data; make_docker "$docker" "$log"; write "$flockbin" '#!/usr/bin/env bash\nexit 0\n'; chmod +x "$flockbin"
  real_git=$(command -v git); make_git_mock "$gitbin" "$real_git" "$log"
  rev1=$(git -C "$repo" rev-parse HEAD); write "$repo/migrations/002.sql" 'select 2;\n'; git -C "$repo" add migrations && git -C "$repo" commit -qm second; rev2=$(git -C "$repo" rev-parse HEAD)
  write "$repo/deploy/.env.production" 'API_DOMAIN=api.example.test\n'; chmod 600 "$repo/deploy/.env.production"
  expect_fail 'validate rejects missing ACM_DATA_DIR before compose' 'ACM_DATA_DIR is missing' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$repo" "$repo/deploy/acm-deploy.sh" validate
  write "$repo/deploy/.env.production" 'ACM_DATA_DIR=relative/data\nAPI_DOMAIN=api.example.test\n'; chmod 600 "$repo/deploy/.env.production"
  expect_fail 'validate rejects relative ACM_DATA_DIR before compose' 'normalized absolute literal' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$repo" "$repo/deploy/acm-deploy.sh" validate
  write "$repo/deploy/.env.production" "ACM_DATA_DIR=\$(touch $FIXTURE/deploy-dotenv-executed)\nAPI_DOMAIN=api.example.test\n"; chmod 600 "$repo/deploy/.env.production"
  expect_fail 'validate rejects interpolated ACM_DATA_DIR before compose' 'normalized absolute literal' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$repo" "$repo/deploy/acm-deploy.sh" validate
  [ ! -e "$FIXTURE/deploy-dotenv-executed" ] || fail 'acm-deploy dotenv payload executed'
  pass 'acm-deploy leaves malformed dotenv inert'
  git -C "$repo" checkout -- deploy/.env.production
  chmod 600 "$repo/deploy/.env.production"
  local common=(env PATH="$(dirname -- "$gitbin"):$PATH" GIT_REAL="$real_git" MOCK_LOG="$log" MOCK_SMOKE_LOG="$log" ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$repo" ACM_DEPLOY_DATA_DIR="$data" ACM_DEPLOY_STATE_DIR="$state" ACM_DEPLOY_LOCK_PATH="$lock" ACM_DEPLOY_DOCKER_BIN="$docker" ACM_DEPLOY_FLOCK_BIN="$flockbin" ACM_DEPLOY_WAIT_TIMEOUT=2 ACM_DB_TEST_MODE=1 ACM_DATA_DIR="$data" ACM_ENV_FILE="$repo/deploy/.env.production" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$repo/deploy/acm-deploy.sh")
  write "$repo/unrelated-untracked" retained
  expect_fail 'lifecycle rejects unrelated untracked files' 'nontracked checkout entry is not allowed' "${common[@]}" initial "$rev1"
  mv "$repo/unrelated-untracked" "$FIXTURE/retained-unrelated-untracked"
  expect_fail 'initial rejects existing database' 'initial refuses existing production SQLite files' "${common[@]}" initial "$rev1"
  write "$data/db.sqlite-journal" stale
  expect_fail 'initial rejects stale SQLite journal' 'initial refuses existing production SQLite files' "${common[@]}" initial "$rev1"
  mv "$data/db.sqlite-journal" "$FIXTURE/retained-stale-journal"
  write "$data/db.sqlite-mj-retained" stale
  expect_fail 'initial rejects extra SQLite sidecar' 'initial refuses existing production SQLite files' "${common[@]}" initial "$rev1"
  mv "$data/db.sqlite-mj-retained" "$FIXTURE/retained-extra-sqlite-sidecar"
  write "$state/production-state.env" "action=initial\nprior_revision=0000000000000000000000000000000000000000\ntarget_revision=0000000000000000000000000000000000000000\nbackup_dir=\nbackup_source_revision=\nbackup_migration_identity=\ntarget_migration_identity=0000000000000000000000000000000000000000000000000000000000000000\nphase=complete\nfailed_phase=\nstarted_at=\nupdated_at=\ncompleted_at=\nstatus=completed\nlast_exit_status=0\n"
  expect_fail 'initial rejects completed state' 'initial requires no deployment state' "${common[@]}" initial "$rev1"
  mv "$state/production-state.env" "$state/production-state.completed-fixture.env"
  write "$state/production-state.env" "action=initial\nprior_revision=0000000000000000000000000000000000000000\ntarget_revision=0000000000000000000000000000000000000000\nbackup_dir=\nbackup_source_revision=\nbackup_migration_identity=\ntarget_migration_identity=0000000000000000000000000000000000000000000000000000000000000000\nphase=acknowledged\nfailed_phase=\nstarted_at=\nupdated_at=\ncompleted_at=\nstatus=acknowledged\nlast_exit_status=0\n"
  expect_fail 'initial rejects acknowledged state' 'initial requires no deployment state' "${common[@]}" initial "$rev1"
  mv "$state/production-state.env" "$state/production-state.acknowledged-fixture.env"
  : > "$state/production-state.env"
  expect_fail 'initial rejects existing state' 'initial requires no deployment state' "${common[@]}" initial "$rev1"
  mv "$state/production-state.env" "$state/production-state.empty-fixture.env"
  # Use the real helper to make canonical metadata, then retain it as the deploy fixture.
  local dbout; dbout=$(env ACM_DB_TEST_MODE=1 ACM_DATA_DIR="$data" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flockbin" ACM_DB_LOCK_PATH="$lock" "$repo/deploy/acm-db.sh" --repository-dir "$repo" backup --backup-root "$backuproot")
  backup=${dbout#BACKUP_DIR=}; [ -f "$backup/COMPLETE" ] || fail 'backup fixture is incomplete'
  bad_backup="$backuproot/wrong-migration"; cp -R "$backup" "$bad_backup"; chmod 0700 "$bad_backup"; chmod 0600 "$bad_backup/metadata.txt" "$bad_backup/manifest.sha256"
  local created revision db_hash metadata_hash bad_migration
  while IFS= read -r line; do case "$line" in created_utc=*) created=${line#*=};; source_revision=*) revision=${line#*=};; esac; done < "$bad_backup/metadata.txt"
  bad_migration=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf 'created_utc=%s\nformat=acm-sqlite-backup-v2\nsource_revision=%s\nmigration_identity=%s\n' "$created" "$revision" "$bad_migration" > "$bad_backup/metadata.txt"
  hash_file(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }
  metadata_hash=$(hash_file "$bad_backup/metadata.txt"); db_hash=$(hash_file "$bad_backup/db.sqlite")
  printf 'format=acm-sqlite-manifest-v2\nsource_revision=%s\nmigration_identity=%s\nmetadata_sha256=%s\n%s  db.sqlite\n' "$revision" "$bad_migration" "$metadata_hash" "$db_hash" > "$bad_backup/manifest.sha256"
  chmod 0400 "$bad_backup"/*
  chmod 0500 "$bad_backup"
  git -C "$repo" checkout -q --detach "$rev1"
  expect_fail 'deploy rejects backup from wrong source before checkout' 'backup source revision is not the current checkout' "${common[@]}" deploy "$rev2" --backup "$backup"
  git -C "$repo" checkout -q --detach "$rev2"
  expect_fail 'deploy rejects backup with wrong migration before checkout' 'backup migration identity is not the current checkout' "${common[@]}" deploy "$rev1" --backup "$bad_backup"
  expect_fail 'rollback rejects backup from wrong target before checkout' 'rollback backup source revision does not match target' "${common[@]}" rollback "$rev1" --backup "$backup"
  # A rollback with matching metadata checks out and builds, but deliberately does not start services.
  git -C "$repo" checkout -q --detach "$rev1"
  : > "$log"
  expect_ok 'rollback prepares matching backup' "${common[@]}" rollback "$rev2" --backup "$backup"
  grep -Fq 'checkout --detach' "$log" || fail 'rollback did not check out target revision'
  grep -Fq ' build' "$log" || fail 'rollback did not build target revision'
  ! grep -Eq '(^| )up( |$)| start( |$)|^smoke( |$)' "$log" || fail 'rollback started services or smoke test'
  [ -f "$state/production-state.env" ] || fail 'rollback did not write state'
  grep -Fxq 'phase=rollback_prepared' "$state/production-state.env" || fail 'rollback state is not rollback_prepared'
  grep -Fxq 'status=prepared' "$state/production-state.env" || fail 'rollback state is not prepared'
  pass 'rollback records rollback_prepared without up or smoke'
  state_mode=$(stat -c '%a' "$state/production-state.env" 2>/dev/null || stat -f '%Lp' "$state/production-state.env")
  [ "$state_mode" = 600 ] || fail "rollback state mode is $state_mode, expected 600"
  pass 'rollback state is mode 0600'
  expect_fail 'prepared state cannot be overwritten' 'existing deployment state is not completed' "${common[@]}" deploy "$rev1" --backup "$backup"
  expect_fail 'generic up refuses incomplete rollback' 'up refuses an incomplete rollback state' "${common[@]}" up
  expect_fail 'rollback-start rejects a different verified backup' 'backup metadata does not exactly match rollback state' "${common[@]}" rollback-start --backup "$bad_backup"
  expect_ok 'rollback-start completes only with exact prepared state and backup' "${common[@]}" rollback-start --backup "$backup"
  grep -Fxq 'status=completed' "$state/production-state.env" || fail 'rollback-start did not complete state'
  pass 'completed state is overwritable according to lifecycle contract'
  : > "$state/production-state.env"
  expect_fail 'malformed state cannot be overwritten' 'missing deployment state field' "${common[@]}" deploy "$rev2" --backup "$backup"
  mv "$state/production-state.env" "$state/production-state.malformed-fixture.env"
  for mode in fail-build fail-up fail-smoke; do
    make_docker "$docker" "$log" "$mode"
    local deploy_out deploy_status
    set +e
    if [ "$mode" = fail-smoke ]; then deploy_out=$(env MOCK_SMOKE_MODE=fail "${common[@]}" deploy "$rev2" --backup "$backup" 2>&1); else deploy_out=$("${common[@]}" deploy "$rev2" --backup "$backup" 2>&1); fi
    deploy_status=$?
    set -e
    [ "$deploy_status" -ne 0 ] || fail "deploy $mode unexpectedly succeeded: $deploy_out"
    [ -f "$state/production-state.env" ] || fail "deploy $mode did not write failure state: $deploy_out"
    grep -Fxq 'phase=failed' "$state/production-state.env" || fail "deploy $mode did not enter failed phase"
    case "$mode" in fail-build) expected_phase=build_pending;; fail-up) expected_phase=up_pending;; fail-smoke) expected_phase=smoke_pending;; esac
    grep -Fxq "failed_phase=$expected_phase" "$state/production-state.env" || fail "deploy $mode recorded wrong failed phase"
    grep -Eq '^last_exit_status=[1-9][0-9]*$' "$state/production-state.env" || fail "deploy $mode recorded a zero exit status"
    pass "deploy $mode records failed state"
    expect_fail "deploy $mode state cannot be overwritten" 'existing deployment state is not completed' "${common[@]}" deploy "$rev2" --backup "$backup"
    local acknowledged
    acknowledged=$("${common[@]}" acknowledge-state) || fail "deploy $mode state could not be acknowledged"
    [[ "$acknowledged" == *'preserved evidence at '* ]] || fail "deploy $mode acknowledgment did not preserve evidence"
    compgen -G "$state/production-state.*.ack.env" >/dev/null || fail "deploy $mode acknowledgment did not archive state"
    pass "deploy $mode acknowledgment preserves evidence and permits next lifecycle"
  done
}

smoke_tests() {
  local envfile="$FIXTURE/smoke.env" compose="$FIXTURE/smoke.yml" docker="$FIXTURE/docker-smoke" log="$FIXTURE/smoke.log" timeoutbin="$FIXTURE/timeout" timeoutlog="$FIXTURE/timeout.log" curlbin="$FIXTURE/curl" curllog="$FIXTURE/curl.log" wrapper_count out
  write "$envfile" 'API_DOMAIN=api.example.test\n'; write "$compose" 'services: {}\n'; make_docker "$docker" "$log" hang
  write "$timeoutbin" '#!/usr/bin/env bash
printf "%s\\n" "$*" >> "${MOCK_TIMEOUT_LOG:?}"
shift; shift; "$@"
'; chmod +x "$timeoutbin"
  write "$curlbin" '#!/usr/bin/env bash\nexit 22\n'; chmod +x "$curlbin"
  expect_fail 'smoke rejects production overrides' 'overrides require --test-mode' env SMOKE_DOCKER_BIN="$docker" "$ROOT/deploy/smoke.sh"
  write "$envfile" "API_DOMAIN=\$(touch $FIXTURE/smoke-executed)\n"
  expect_fail 'smoke leaves malicious env inert' 'missing or invalid' env MOCK_TIMEOUT_LOG="$timeoutlog" SMOKE_TEST_MODE=1 SMOKE_ENV_FILE="$envfile" SMOKE_COMPOSE_FILE="$compose" SMOKE_TIMEOUT_BIN="$timeoutbin" "$ROOT/deploy/smoke.sh" --test-mode
  [ ! -e "$FIXTURE/smoke-executed" ] || fail 'smoke dotenv payload executed'; pass 'smoke does not execute env input'
  write "$envfile" 'API_DOMAIN=api.example.test\n'
  out=$(env HTTPS_PROXY=http://proxy.invalid:8080 SMOKE_TEST_MODE=1 SMOKE_ENV_FILE="$envfile" SMOKE_COMPOSE_FILE="$compose" "$ROOT/deploy/smoke.sh" --test-mode --dry-run)
  [[ "$out" != *'--noproxy '* ]] || fail 'smoke DNS dry-run unexpectedly bypasses proxy'
  pass 'smoke DNS dry-run preserves proxy routing'
  out=$(env HTTPS_PROXY=http://proxy.invalid:8080 SMOKE_TEST_MODE=1 SMOKE_ENV_FILE="$envfile" SMOKE_COMPOSE_FILE="$compose" "$ROOT/deploy/smoke.sh" --test-mode --dry-run --resolve)
  [[ "$out" == *'--resolve api.example.test:443:127.0.0.1 --noproxy api.example.test '* ]] || fail 'smoke dry-run omits local resolve proxy bypass'
  pass 'smoke dry-run prints local resolve proxy bypass'
  write "$curlbin" '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "${MOCK_CURL_LOG:?}"\n'; chmod +x "$curlbin"; make_docker "$docker" "$log"
  : > "$curllog"; expect_ok 'smoke local resolve bypasses proxy' env HTTPS_PROXY=http://proxy.invalid:8080 MOCK_TIMEOUT_LOG="$timeoutlog" MOCK_CURL_LOG="$curllog" SMOKE_TEST_MODE=1 SMOKE_ENV_FILE="$envfile" SMOKE_COMPOSE_FILE="$compose" SMOKE_DOCKER_BIN="$docker" SMOKE_TIMEOUT_BIN="$timeoutbin" SMOKE_CURL_BIN="$curlbin" SMOKE_RETRIES=1 SMOKE_RETRY_DELAY=0 SMOKE_DEADLINE_SECONDS=5 SMOKE_COMMAND_TIMEOUT=1 "$ROOT/deploy/smoke.sh" --test-mode --resolve
  grep -Fq -- '--resolve api.example.test:443:127.0.0.1 --noproxy api.example.test' "$curllog" || fail 'smoke local resolve curl omitted proxy bypass'
  pass 'smoke local resolve curl uses proxy bypass'
  make_docker "$docker" "$log" health-fail
  : > "$timeoutlog"
  expect_fail 'smoke distinguishes unhealthy service' 'service not healthy' env MOCK_TIMEOUT_LOG="$timeoutlog" SMOKE_TEST_MODE=1 SMOKE_ENV_FILE="$envfile" SMOKE_COMPOSE_FILE="$compose" SMOKE_DOCKER_BIN="$docker" SMOKE_TIMEOUT_BIN="$timeoutbin" SMOKE_CURL_BIN="$curlbin" SMOKE_RETRIES=1 SMOKE_RETRY_DELAY=0 SMOKE_DEADLINE_SECONDS=1 SMOKE_COMMAND_TIMEOUT=1 "$ROOT/deploy/smoke.sh" --test-mode
  wrapper_count=$(grep -c -- "$ROOT/deploy/smoke.sh" "$timeoutlog" || true)
  [ "$wrapper_count" = 1 ] || fail "smoke wrapper re-executed $wrapper_count times"
  pass 'smoke executes exactly one deadline wrapper'
  local health_status
  set +e; env MOCK_TIMEOUT_LOG="$timeoutlog" SMOKE_TEST_MODE=1 SMOKE_ENV_FILE="$envfile" SMOKE_COMPOSE_FILE="$compose" SMOKE_DOCKER_BIN="$docker" SMOKE_TIMEOUT_BIN="$timeoutbin" SMOKE_CURL_BIN="$curlbin" SMOKE_RETRIES=1 SMOKE_RETRY_DELAY=0 SMOKE_DEADLINE_SECONDS=5 SMOKE_COMMAND_TIMEOUT=1 "$ROOT/deploy/smoke.sh" --test-mode >/dev/null 2>&1; health_status=$?; set -e
  [ "$health_status" -ne 124 ] || fail 'ordinary unhealthy service was reported as a deadline timeout'
  pass 'smoke distinguishes health failure from timeout'
  if command -v timeout >/dev/null 2>&1; then
    make_docker "$docker" "$log" hang
    expect_status 'smoke hard deadline returns 124 for hanging Docker' 124 env SMOKE_TEST_MODE=1 SMOKE_ENV_FILE="$envfile" SMOKE_COMPOSE_FILE="$compose" SMOKE_DOCKER_BIN="$docker" SMOKE_TIMEOUT_BIN=timeout SMOKE_CURL_BIN="$curlbin" SMOKE_RETRIES=1 SMOKE_RETRY_DELAY=0 SMOKE_DEADLINE_SECONDS=1 SMOKE_COMMAND_TIMEOUT=1 "$ROOT/deploy/smoke.sh" --test-mode
  else
    skip 'smoke hard deadline' 'timeout is unavailable on this host'
  fi
}

bootstrap_tests
db_tests
deploy_tests
smoke_tests
printf '1..%s # %s skipped; fixtures retained at %s\n' "$((PASS + SKIP))" "$SKIP" "$FIXTURE"
