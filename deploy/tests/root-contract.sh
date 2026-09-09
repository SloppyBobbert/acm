#!/usr/bin/env bash
# Root and lock contract tests. Fixtures are deliberately retained.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
FIXTURE=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/tmp}/acm-root-contract.XXXXXX")" && pwd -P)
PASS=0
pass(){ PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$*" >&2; exit 1; }
expect_fail(){ local label=$1 needle=$2 out status; shift 2; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" -ne 0 ] || fail "$label unexpectedly succeeded"; [[ "$out" == *"$needle"* ]] || fail "$label missing $needle: $out"; pass "$label"; }
expect_ok(){ local label=$1 out status; shift; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" = 0 ] || fail "$label failed: $out"; pass "$label"; }
mode(){ stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
write(){ mkdir -p "$(dirname -- "$1")"; printf '%b' "$2" > "$1"; }
HOLDER=''
HOLDER_PID='' HOLDER_CONTROL=''
stop_holder(){ local i; [ -z "$HOLDER" ] && return; : > "$HOLDER_CONTROL/release"; for i in $(seq 1 30); do kill -0 "$HOLDER_PID" 2>/dev/null || break; sleep 0.1; done; if kill -0 "$HOLDER_PID" 2>/dev/null; then kill -TERM "$HOLDER_PID" 2>/dev/null || true; for i in $(seq 1 10); do kill -0 "$HOLDER_PID" 2>/dev/null || break; sleep 0.1; done; fi; if kill -0 "$HOLDER_PID" 2>/dev/null; then kill -KILL "$HOLDER_PID" 2>/dev/null || true; fi; kill -0 "$HOLDER" 2>/dev/null || wait "$HOLDER" 2>/dev/null || true; HOLDER=''; }
release_holder(){ : > "$HOLDER_CONTROL/release"; for _ in $(seq 1 30); do kill -0 "$HOLDER_PID" 2>/dev/null || break; sleep 0.1; done; kill -0 "$HOLDER_PID" 2>/dev/null && fail 'lock holder did not release'; wait "$HOLDER" || fail 'lock holder did not exit zero'; HOLDER=''; flock -n "$LOCK" true || fail 'lock was not released after holder cleanup'; }
start_holder(){ local i; HOLDER_CONTROL="$FIXTURE/flock-control"; mkdir -m 0700 "$HOLDER_CONTROL"; bash "$ROOT/deploy/tests/support/lock-holder.sh" "$LOCK" "$HOLDER_CONTROL" flock 3000 & HOLDER=$!; for i in $(seq 1 30); do [ -f "$HOLDER_CONTROL/ready" ] && break; kill -0 "$HOLDER" 2>/dev/null || fail 'lock holder exited before ready'; sleep 0.1; done; [ -f "$HOLDER_CONTROL/ready" ] || fail 'lock holder did not become ready'; HOLDER_PID=$(<"$HOLDER_CONTROL/pid"); [[ "$HOLDER_PID" =~ ^[1-9][0-9]*$ ]] && kill -0 "$HOLDER_PID" 2>/dev/null || fail 'lock holder PID is invalid'; }
trap stop_holder EXIT

REPO=$FIXTURE/repo DATA=$FIXTURE/data STATE=$FIXTURE/state LOCK=$FIXTURE/locks/acm-operation.lock LOG=$FIXTURE/docker.log
FLOCK_BIN=flock
command -v flock >/dev/null 2>&1 || FLOCK_BIN=true
mkdir -p "$REPO/deploy" "$REPO/migrations" "$DATA"
cp "$ROOT/deploy/acm-deploy.sh" "$ROOT/deploy/acm-db.sh" "$REPO/deploy/"
write "$REPO/deploy/smoke.sh" '#!/usr/bin/env bash\nexit 0\n'
write "$REPO/compose.production.yml" 'services: {}\n'
write "$REPO/deploy/.env.production" "ACM_DATA_DIR=$DATA\n"
write "$REPO/migrations/001.sql" 'select 1;\n'
write "$REPO/.gitignore" 'ignored-nonallowlisted\n'
chmod 0600 "$REPO/deploy/.env.production"; chmod 0755 "$REPO/deploy/smoke.sh"; chmod 0750 "$DATA"
git -C "$REPO" init -q; git -C "$REPO" config user.email root-contract@example.test; git -C "$REPO" config user.name root-contract; git -C "$REPO" add . && git -C "$REPO" commit -qm initial
REV=$(git -C "$REPO" rev-parse HEAD)
write "$FIXTURE/docker" '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "${MOCK_LOG:?}"\n'
chmod 0755 "$FIXTURE/docker"
COMMON=(env MOCK_LOG="$LOG" ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_TEST_EUID=0 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$LOCK" ACM_DEPLOY_DOCKER_BIN="$FIXTURE/docker" ACM_DEPLOY_FLOCK_BIN="$FLOCK_BIN" ACM_DEPLOY_WAIT_TIMEOUT=1 "$ROOT/deploy/acm-deploy.sh")
DB=(env ACM_DB_TEST_MODE=1 ACM_DB_TEST_EUID=0 ACM_DATA_DIR="$DATA" ACM_ENV_FILE="$REPO/deploy/.env.production" ACM_DOCKER_BIN="$FIXTURE/docker" ACM_FLOCK_BIN="$FLOCK_BIN" ACM_DB_LOCK_PATH="$LOCK" "$ROOT/deploy/acm-db.sh" --repository-dir "$REPO")

# Root rejection is intentionally first: no lock, state, or Docker side effect may precede it.
for command in "initial $REV" "deploy $REV --backup $FIXTURE/no-backup" "rollback $REV --backup $FIXTURE/no-backup" "rollback-start --backup $FIXTURE/no-backup" "acknowledge-state" "build" "up"; do
  IFS=' ' read -r -a args <<< "$command"
  : > "$LOG"; expect_fail "non-root deploy $command is rejected before mutation" 'mutating lifecycle commands require effective UID 0' env MOCK_LOG="$LOG" ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_TEST_EUID=501 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$LOCK" ACM_DEPLOY_DOCKER_BIN="$FIXTURE/docker" ACM_DEPLOY_FLOCK_BIN=flock "$ROOT/deploy/acm-deploy.sh" "${args[@]}"
  [ ! -e "$LOCK" ] && [ ! -e "$STATE/production-state.env" ] && [ ! -s "$LOG" ] || fail "non-root deploy $command mutated fixture"
done
for command in "backup --backup-root $FIXTURE/backups" "restore --backup-dir $FIXTURE/no-backup --yes-restore"; do
  IFS=' ' read -r -a args <<< "$command"
  : > "$LOG"; expect_fail "non-root database $command is rejected" 'backup and restore require effective UID 0' env ACM_DB_TEST_MODE=1 ACM_DB_TEST_EUID=501 ACM_DATA_DIR="$DATA" ACM_ENV_FILE="$REPO/deploy/.env.production" ACM_DOCKER_BIN="$FIXTURE/docker" ACM_FLOCK_BIN=flock ACM_DB_LOCK_PATH="$LOCK" "$ROOT/deploy/acm-db.sh" --repository-dir "$REPO" "${args[@]}"
  [ ! -e "$LOCK" ] && [ ! -s "$LOG" ] || fail "non-root database $command mutated fixture"
done

expect_ok 'validate remains available to non-root operators' env MOCK_LOG="$LOG" ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_TEST_EUID=501 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$LOCK" ACM_DEPLOY_DOCKER_BIN="$FIXTURE/docker" "$ROOT/deploy/acm-deploy.sh" validate
expect_ok 'status remains available to non-root operators' env MOCK_LOG="$LOG" ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_TEST_EUID=501 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$LOCK" ACM_DEPLOY_DOCKER_BIN="$FIXTURE/docker" "$ROOT/deploy/acm-deploy.sh" status
: > "$LOG"; expect_ok 'dry-run lifecycle remains available to non-root operators' env MOCK_LOG="$LOG" ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_TEST_EUID=501 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$LOCK" ACM_DEPLOY_DOCKER_BIN="$FIXTURE/docker" "$ROOT/deploy/acm-deploy.sh" --dry-run initial "$REV"
[ ! -e "$LOCK" ] && [ ! -e "$STATE" ] && [ ! -s "$LOG" ] || fail 'dry-run created lock, state, or Docker mutation'
pass 'dry-run creates no lock, state, or Docker mutation'

expect_fail 'symlink compose remains rejected in test mode' 'unsafe tracked path' bash -c 'mv "$1/compose.production.yml" "$1/retained-compose"; ln -s retained-compose "$1/compose.production.yml"; env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$1" ACM_DEPLOY_DATA_DIR="$2" "$3" validate' _ "$REPO" "$DATA" "$ROOT/deploy/acm-deploy.sh"
mv "$REPO/compose.production.yml" "$FIXTURE/retained-compose-symlink"; mv "$REPO/retained-compose" "$REPO/compose.production.yml"
chmod 0660 "$REPO/deploy/.env.production"; expect_fail 'group-writable environment remains rejected in test mode' 'tracked file must not be group- or world-writable' "${COMMON[@]}" validate; chmod 0600 "$REPO/deploy/.env.production"
chmod 0775 "$REPO/migrations"; expect_fail 'group-writable input directory remains rejected in test mode' 'tracked path ancestor must not be group- or world-writable' "${COMMON[@]}" validate; chmod 0755 "$REPO/migrations"
chmod 0666 "$REPO/migrations/001.sql"; expect_fail 'writable tracked file remains rejected in test mode' 'tracked file must not be group- or world-writable' "${COMMON[@]}" validate; chmod 0644 "$REPO/migrations/001.sql"
mkdir -p "$FIXTURE/data-parent/data"; chmod 0755 "$FIXTURE/data-parent"; chmod 0750 "$FIXTURE/data-parent/data"; chmod 0775 "$FIXTURE/data-parent"; expect_fail 'writable data ancestor is rejected in test mode' 'data directory ancestor must not be group- or world-writable' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$FIXTURE/data-parent/data" "$ROOT/deploy/acm-deploy.sh" validate; chmod 0755 "$FIXTURE/data-parent"
mkdir -p "$FIXTURE/data-link-target/data"; chmod 0755 "$FIXTURE/data-link-target"; chmod 0750 "$FIXTURE/data-link-target/data"; ln -s "$FIXTURE/data-link-target" "$FIXTURE/data-link"; expect_fail 'symlink data ancestor is rejected in test mode' 'unsafe data directory ancestor' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$FIXTURE/data-link/data" "$ROOT/deploy/acm-deploy.sh" validate
chmod 0700 "$DATA"; expect_fail 'data directory requires mode 0750 in test mode' 'data directory must be mode 0750' "${COMMON[@]}" validate; chmod 0750 "$DATA"
mkdir -p "$REPO/migrations/nested"; write "$REPO/migrations/nested/002.sql" 'select 2;\n'; git -C "$REPO" add migrations/nested/002.sql && git -C "$REPO" commit -qm nested-migration; chmod 0775 "$REPO/migrations/nested"; expect_fail 'writable nested migration directory is rejected' 'tracked path ancestor must not be group- or world-writable' "${COMMON[@]}" validate; chmod 0755 "$REPO/migrations/nested"
write "$REPO/ignored-nonallowlisted" 'unsafe\n'; git -C "$REPO" check-ignore -q ignored-nonallowlisted || fail 'fixture entry is not ignored'; expect_fail 'ignored nonallowlisted checkout entry is rejected' 'nontracked checkout entry is not allowed' "${COMMON[@]}" validate; mv "$REPO/ignored-nonallowlisted" "$FIXTURE/ignored-nonallowlisted"
mkdir -p "$REPO/.local/deploy"; chmod 0700 "$REPO/.local" "$REPO/.local/deploy"; expect_ok 'operational state allowlist is accepted' "${COMMON[@]}" validate
pass 'test mode skips ownership checks only'

mkdir -p "$FIXTURE/state-target"; ln -s "$FIXTURE/state-target" "$FIXTURE/state-symlink"; expect_fail 'state directory symlink is rejected' 'deployment state is missing' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$FIXTURE/state-symlink" ACM_DEPLOY_LOCK_PATH="$FIXTURE/state-lock/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN="$FLOCK_BIN" "$ROOT/deploy/acm-deploy.sh" rollback-start --backup "$FIXTURE/no"
mkdir -p "$FIXTURE/state-mode"; chmod 0755 "$FIXTURE/state-mode"; expect_fail 'state directory requires mode 0700' 'deployment state directory must be mode 0700' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$FIXTURE/state-mode" ACM_DEPLOY_LOCK_PATH="$FIXTURE/state-lock/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN="$FLOCK_BIN" "$ROOT/deploy/acm-deploy.sh" rollback-start --backup "$FIXTURE/no"
chmod 0700 "$FIXTURE/state-mode"; write "$FIXTURE/state-mode/production-state.env" 'invalid\n'; chmod 0644 "$FIXTURE/state-mode/production-state.env"; expect_fail 'state file requires mode 0600' 'deployment state file must be mode 0600' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$FIXTURE/state-mode" ACM_DEPLOY_LOCK_PATH="$FIXTURE/state-lock/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN="$FLOCK_BIN" "$ROOT/deploy/acm-deploy.sh" rollback-start --backup "$FIXTURE/no"

expect_fail 'lock directory symlink is rejected' 'operation lock directory must be a non-symlink directory' bash -c 'mkdir -p "$1"; ln -s retained "$1/locks"; env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$1/repo" ACM_DEPLOY_DATA_DIR="$1/data" ACM_DEPLOY_STATE_DIR="$1/state" ACM_DEPLOY_LOCK_PATH="$1/locks/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN="$3" "$2" rollback-start --backup "$1/no"' _ "$FIXTURE" "$ROOT/deploy/acm-deploy.sh" "$FLOCK_BIN"
mv "$FIXTURE/locks" "$FIXTURE/retained-locks-symlink"
mkdir -p "$FIXTURE/bad-dir"; chmod 0755 "$FIXTURE/bad-dir"; expect_fail 'wrong-mode lock directory is rejected' 'operation lock directory must be mode 0700' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$FIXTURE/bad-dir/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN="$FLOCK_BIN" "$ROOT/deploy/acm-deploy.sh" rollback-start --backup "$FIXTURE/no"
mkdir -p "$FIXTURE/bad-file"; chmod 0700 "$FIXTURE/bad-file"; write "$FIXTURE/bad-file/acm-operation.lock" x; chmod 0644 "$FIXTURE/bad-file/acm-operation.lock"; expect_fail 'wrong-mode lock file is rejected' 'operation lock must be mode 0600' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$FIXTURE/bad-file/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN="$FLOCK_BIN" "$ROOT/deploy/acm-deploy.sh" rollback-start --backup "$FIXTURE/no"
mkdir -p "$FIXTURE/nonregular-file/acm-operation.lock"; chmod 0700 "$FIXTURE/nonregular-file"; expect_fail 'nonregular lock file is rejected' 'operation lock must be a regular non-symlink file' env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$REPO" ACM_DEPLOY_DATA_DIR="$DATA" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$FIXTURE/nonregular-file/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN="$FLOCK_BIN" "$ROOT/deploy/acm-deploy.sh" rollback-start --backup "$FIXTURE/no"
expect_fail 'absent lock is created before state validation' 'deployment state is missing' "${COMMON[@]}" rollback-start --backup "$FIXTURE/no"
[ "$(mode "$(dirname -- "$LOCK")")" = 700 ] && [ "$(mode "$LOCK")" = 600 ] || fail 'created lock modes are not 0700/0600'; pass 'lock creation uses exact modes'
expect_fail 'valid lock is reused' 'deployment state is missing' "${COMMON[@]}" rollback-start --backup "$FIXTURE/no"
if command -v flock >/dev/null 2>&1; then
  start_holder
  expect_fail 'deployment helper enforces lock contention' 'another ACM operation is active' "${COMMON[@]}" rollback-start --backup "$FIXTURE/no"
  expect_fail 'database helper contends on deployment lock' 'another ACM database operation is active' "${DB[@]}" backup --backup-root "$FIXTURE/backups"
  : > "$LOG"; expect_fail 'standalone build rejects contention before Compose' 'another ACM operation is active' "${COMMON[@]}" build; [ ! -s "$LOG" ] || fail 'standalone build invoked Compose while lock was held'
  : > "$LOG"; expect_fail 'standalone up rejects contention before Compose' 'another ACM operation is active' "${COMMON[@]}" up; [ ! -s "$LOG" ] || fail 'standalone up invoked Compose while lock was held'
  release_holder; pass 'helpers share the operation lock'
else
  printf 'ok - helpers share the operation lock # SKIP flock unavailable\n'
fi
printf '1..%s # fixtures retained at %s\n' "$PASS" "$FIXTURE"
