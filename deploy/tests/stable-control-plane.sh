#!/usr/bin/env bash
# Proves an installed control plane can finish a rollback after legacy checkout.
# Fixtures are retained for inspection.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
FIXTURE=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/tmp}/acm-stable-control-plane.XXXXXX")" && pwd -P)
PASS=0

pass() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
write() { mkdir -p "$(dirname -- "$1")"; printf '%b' "$2" > "$1"; }
expect_ok() { local label=$1 out status; shift; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" = 0 ] || fail "$label failed: $out"; pass "$label"; }
expect_fail() { local label=$1 needle=$2 out status; shift 2; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" -ne 0 ] || fail "$label unexpectedly succeeded"; [[ "$out" == *"$needle"* ]] || fail "$label missing '$needle': $out"; pass "$label"; }

REPO=$FIXTURE/repository
INSTALLED=$FIXTURE/installed
DATA=$FIXTURE/data
BACKUPS=$FIXTURE/backups
STATE=$REPO/.local/deploy
BIN=$FIXTURE/bin
ENV_FILE=$FIXTURE/production.env
LOCK=$FIXTURE/acm.lock
LOG=$FIXTURE/operations.log
TIMEOUT_LOG=$FIXTURE/timeout.log
mkdir -p "$REPO/deploy" "$REPO/migrations" "$INSTALLED" "$DATA" "$BACKUPS" "$BIN"
chmod 0750 "$DATA"
chmod 0700 "$BACKUPS"

write "$REPO/compose.production.yml" 'services: {}\n'
write "$REPO/migrations/001.sql" 'select 1;\n'
git -C "$REPO" init -q
git -C "$REPO" config user.email stable-control-plane@example.test
git -C "$REPO" config user.name stable-control-plane
git -C "$REPO" add compose.production.yml migrations
git -C "$REPO" commit -qm legacy
LEGACY=$(git -C "$REPO" rev-parse HEAD)

# This is deliberately outside the legacy checkout: acm-db must be able to
# make the backup while the legacy repository has no ignore rules.
write "$ENV_FILE" "ACM_DATA_DIR=$DATA\nAPI_DOMAIN=api.example.test\n"
chmod 600 "$ENV_FILE"
write "$DATA/db.sqlite" database

write "$BIN/flock" '#!/usr/bin/env bash\nexit 0\n'
write "$BIN/docker" '#!/usr/bin/env bash
printf "%s\\n" "$*" >> "${MOCK_LOG:?}"
if [[ "$*" == *"ps -q"* ]]; then printf "container\\n"; fi
if [[ "${1:-}" = inspect ]]; then printf "running healthy\\n"; fi
'
write "$BIN/curl" '#!/usr/bin/env bash
printf "%s\\n" "$*" >> "${MOCK_LOG:?}"
exit 0
'
write "$BIN/timeout" '#!/usr/bin/env bash
printf "%s\\n" "$*" >> "${MOCK_TIMEOUT_LOG:?}"
shift
shift
"$@"
'
chmod +x "$BIN/flock" "$BIN/docker" "$BIN/curl" "$BIN/timeout"

cp "$ROOT/deploy/acm-deploy.sh" "$ROOT/deploy/acm-db.sh" "$ROOT/deploy/smoke.sh" "$INSTALLED/"
chmod +x "$INSTALLED/acm-deploy.sh" "$INSTALLED/acm-db.sh" "$INSTALLED/smoke.sh"

backup_output=$(env PATH="$BIN:$PATH" MOCK_LOG="$LOG" ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$ENV_FILE" ACM_DOCKER_BIN=docker ACM_FLOCK_BIN=flock ACM_DB_LOCK_PATH="$LOCK" "$INSTALLED/acm-db.sh" --repository-dir "$REPO" backup --backup-root "$BACKUPS")
BACKUP=${backup_output#BACKUP_DIR=}
[ -d "$BACKUP" ] && [ -f "$BACKUP/COMPLETE" ] || fail 'real external acm-db did not create a complete backup'
pass 'real external acm-db creates a legacy-head backup using production.env override'

# The newer checkout has local toolkit scripts, but the control plane invoked
# below is the independent installed copy.
mkdir -p "$REPO/deploy"
cp "$ROOT/deploy/acm-deploy.sh" "$ROOT/deploy/acm-db.sh" "$ROOT/deploy/smoke.sh" "$REPO/deploy/"
chmod +x "$REPO/deploy/acm-deploy.sh" "$REPO/deploy/acm-db.sh" "$REPO/deploy/smoke.sh"
git -C "$REPO" add deploy
git -C "$REPO" commit -qm toolkit

# Both operational paths are intentionally untracked; only the unrelated file
# below may make require_clean reject the lifecycle operation.
mkdir -p "$STATE"
chmod 0700 "$REPO/.local" "$STATE"
write "$REPO/deploy/.env.production" "ACM_DATA_DIR=$DATA\nAPI_DOMAIN=api.example.test\n"
chmod 600 "$REPO/deploy/.env.production"
write "$STATE/operator-note" retained
write "$REPO/unrelated-untracked" retained
COMMON=(env PATH="$BIN:$PATH" MOCK_LOG="$LOG" MOCK_TIMEOUT_LOG="$TIMEOUT_LOG" ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_ENV_FILE="$ENV_FILE" ACM_DEPLOY_STATE_DIR="$STATE" ACM_DEPLOY_LOCK_PATH="$LOCK" ACM_DEPLOY_DOCKER_BIN=docker ACM_DEPLOY_FLOCK_BIN=flock ACM_DEPLOY_WAIT_TIMEOUT=2 ACM_DB_TEST_MODE=1 ACM_DATA_DIR="$DATA" ACM_ENV_FILE="$ENV_FILE" ACM_DOCKER_BIN=docker ACM_FLOCK_BIN=flock ACM_DB_LOCK_PATH="$LOCK" "$INSTALLED/acm-deploy.sh" --repository-dir "$REPO")
expect_fail 'unrelated untracked file rejects rollback despite operational env and state' 'nontracked checkout entry is not allowed' "${COMMON[@]}" rollback "$LEGACY" --backup "$BACKUP"
mv "$REPO/unrelated-untracked" "$FIXTURE/retained-unrelated-untracked"

: > "$LOG"
expect_ok 'external runner prepares rollback to scriptless legacy target' "${COMMON[@]}" rollback "$LEGACY" --backup "$BACKUP"
[ ! -e "$REPO/deploy/acm-deploy.sh" ] && [ ! -e "$REPO/deploy/acm-db.sh" ] && [ ! -e "$REPO/deploy/smoke.sh" ] || fail 'legacy checkout retained repository deploy scripts'
[ -x "$INSTALLED/acm-deploy.sh" ] && [ -x "$INSTALLED/acm-db.sh" ] && [ -x "$INSTALLED/smoke.sh" ] || fail 'installed helpers did not remain executable'
grep -Fxq 'phase=rollback_prepared' "$STATE/production-state.env" || fail 'rollback state is not rollback_prepared'
grep -Fxq 'status=prepared' "$STATE/production-state.env" || fail 'rollback state is not prepared'
grep -Fq ' build' "$LOG" || fail 'rollback did not build legacy target'
! grep -Eq '(^| )up( |$)|smoke' "$LOG" || fail 'rollback preparation ran up or smoke'
pass 'rollback preparation removes repository helpers and stops before up or smoke'

: > "$LOG"
: > "$TIMEOUT_LOG"
expect_ok 'external runner starts prepared legacy rollback' "${COMMON[@]}" rollback-start --backup "$BACKUP"
grep -Fq 'up -d --wait --wait-timeout 2' "$LOG" || fail 'rollback-start did not run compose up --wait'
grep -Fq 'https://api.example.test/healthz' "$LOG" || fail 'external smoke did not run public health check'
grep -Fxq 'phase=complete' "$STATE/production-state.env" || fail 'rollback-start state is not complete'
grep -Fxq 'status=completed' "$STATE/production-state.env" || fail 'rollback-start state is not completed'
wrapper_count=$(grep -Fc "$INSTALLED/smoke.sh --repository-dir $REPO" "$TIMEOUT_LOG" || true)
[ "$wrapper_count" = 1 ] || fail "external smoke used $wrapper_count deadline wrappers instead of one"
pass 'external smoke preserves repository path through exactly one deadline wrapper'

grep -Fq -- '--repository-dir' "$INSTALLED/acm-deploy.sh" || fail 'installed lifecycle helper lacks repository argument support'
grep -Fq -- '--repository-dir' "$INSTALLED/acm-db.sh" || fail 'installed database helper lacks repository argument support'
pass 'installed control-plane helpers retain repository argument support'

printf '1..%s # fixtures retained at %s\n' "$PASS" "$FIXTURE"
