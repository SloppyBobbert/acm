#!/usr/bin/env bash
# Linux-only production ownership integration. Its /srv fixture is retained.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
if [ "$(uname -s)" = Darwin ]; then
  printf '1..1 # SKIP Linux root ownership integration is not applicable on Darwin\n'
  exit 0
fi
if ! sudo -n true; then
  printf 'not ok - passwordless sudo is required for Linux ownership integration\n' >&2
  exit 1
fi

FIXTURE=/srv/acm-ownership-test-$(date +%s)-$$
PASS=0
pass(){ PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$*" >&2; exit 1; }
expect_fail(){ local label=$1 needle=$2 out status; shift 2; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" -ne 0 ] || fail "$label unexpectedly succeeded"; [[ "$out" == *"$needle"* ]] || fail "$label missing $needle: $out"; pass "$label"; }
expect_ok(){ local label=$1 out status; shift; set +e; out=$("$@" 2>&1); status=$?; set -e; [ "$status" = 0 ] || fail "$label failed: $out"; pass "$label"; }
mode(){ sudo stat -c '%a' "$1"; }
owner(){ sudo stat -c '%u:%g' "$1"; }

sudo install -d -o root -g root -m 0755 "$FIXTURE" "$FIXTURE/repo" "$FIXTURE/repo/deploy" "$FIXTURE/repo/migrations" "$FIXTURE/bin"
sudo install -d -o 10001 -g 10001 -m 0750 "$FIXTURE/data"
sudo install -o root -g root -m 0755 "$ROOT/deploy/acm-deploy.sh" "$FIXTURE/repo/deploy/acm-deploy.sh"
sudo install -o root -g root -m 0755 "$ROOT/deploy/acm-db.sh" "$FIXTURE/repo/deploy/acm-db.sh"
sudo install -o root -g root -m 0755 "$ROOT/deploy/smoke.sh" "$FIXTURE/repo/deploy/smoke.sh"
sudo sh -c "printf '%s\\n' 'services: {}' > '$FIXTURE/repo/compose.production.yml'"
sudo sh -c "printf '%s\\n' 'ACM_DATA_DIR=$FIXTURE/data' 'API_DOMAIN=api.ownership.test' > '$FIXTURE/repo/deploy/.env.production'"
sudo sh -c "printf '%s\\n' 'select 1;' > '$FIXTURE/repo/migrations/001.sql'"
sudo tee "$FIXTURE/bin/docker" >/dev/null <<'MOCK_DOCKER'
#!/usr/bin/env bash
printf '%s\n' "docker $*" >> "${MOCK_LOG:?}"
if [[ "$*" == *"ps -q"* ]]; then printf 'container-%s\n' "${*: -1}"; fi
if [ "${1:-}" = inspect ]; then printf 'running healthy\n'; fi
MOCK_DOCKER
sudo tee "$FIXTURE/bin/curl" >/dev/null <<'MOCK_CURL'
#!/usr/bin/env bash
printf '%s\n' "curl $*" >> "${MOCK_LOG:?}"
[[ "$*" == *"https://api.ownership.test/healthz"* ]]
MOCK_CURL
sudo tee "$FIXTURE/bin/timeout" >/dev/null <<'MOCK_TIMEOUT'
#!/usr/bin/env bash
printf '%s\n' "timeout $*" >> "${MOCK_LOG:?}"
if [ "${1:-}" = --foreground ]; then shift; fi
shift
exec "$@"
MOCK_TIMEOUT
sudo chmod 0644 "$FIXTURE/repo/compose.production.yml" "$FIXTURE/repo/migrations/001.sql"
sudo chmod 0600 "$FIXTURE/repo/deploy/.env.production"
sudo chmod 0755 "$FIXTURE/bin/docker" "$FIXTURE/bin/curl" "$FIXTURE/bin/timeout"
sudo chown root:root "$FIXTURE/bin/docker" "$FIXTURE/bin/curl" "$FIXTURE/bin/timeout"
MOCK_VERIFY_LOG=$(mktemp "${TMPDIR:-/tmp}/acm-linux-mock.XXXXXX")
for mock in docker curl timeout; do
  bash -n "$FIXTURE/bin/$mock" || fail "generated $mock mock syntax is invalid"
done
MOCK_LOG="$MOCK_VERIFY_LOG" "$FIXTURE/bin/docker" compose ps -q server >/dev/null || fail 'generated docker mock is invalid'
MOCK_LOG="$MOCK_VERIFY_LOG" "$FIXTURE/bin/curl" https://api.ownership.test/healthz || fail 'generated curl mock is invalid'
MOCK_LOG="$MOCK_VERIFY_LOG" "$FIXTURE/bin/timeout" --foreground 1 /usr/bin/true || fail 'generated timeout mock is invalid'
sudo git -C "$FIXTURE/repo" init -q
sudo git -C "$FIXTURE/repo" config user.email ownership@example.test
sudo git -C "$FIXTURE/repo" config user.name ownership
sudo git -C "$FIXTURE/repo" add . && sudo git -C "$FIXTURE/repo" commit -qm initial
sudo install -o "$(id -u)" -g "$(id -g)" -m 0600 /dev/null "$FIXTURE/operations.log"

# Production validate reaches Docker only after root ownership and mode checks.
expect_ok 'production validate accepts root-owned safe checkout' sudo env PATH="$FIXTURE/bin:$PATH" MOCK_LOG="$FIXTURE/operations.log" "$ROOT/deploy/acm-deploy.sh" --repository-dir "$FIXTURE/repo" validate
sudo chmod 0664 "$FIXTURE/repo/compose.production.yml"
expect_fail 'production rejects group-writable input' 'must not be group- or world-writable' sudo env PATH="$FIXTURE/bin:$PATH" MOCK_LOG="$FIXTURE/operations.log" "$ROOT/deploy/acm-deploy.sh" --repository-dir "$FIXTURE/repo" validate
sudo chmod 0644 "$FIXTURE/repo/compose.production.yml"
OTHER_UID=$(awk -F: '$3 != 0 { print $3; exit }' /etc/passwd)
if [ -n "${OTHER_UID:-}" ]; then
  sudo chown "$OTHER_UID":0 "$FIXTURE/repo/migrations/001.sql"
  expect_fail 'production rejects non-root-owned input' 'must be owned by root:root' sudo env PATH="$FIXTURE/bin:$PATH" MOCK_LOG="$FIXTURE/operations.log" "$ROOT/deploy/acm-deploy.sh" --repository-dir "$FIXTURE/repo" validate
  sudo chown root:root "$FIXTURE/repo/migrations/001.sql"
else
  printf 'ok - production rejects non-root-owned input # SKIP no non-root UID is available\n'
fi

# Initial is a deterministic mocked lifecycle path: Docker, curl, and timeout
# cannot contact a daemon or network; flock remains the host implementation.
REV=$(sudo git -C "$FIXTURE/repo" rev-parse HEAD)
sudo test -d /run/lock && sudo test ! -L /run/lock || fail 'global /run/lock is unsafe'
before_lock=$(sudo stat -c '%u:%g:%a' /run/lock)
expect_ok 'production initial completes with controlled lifecycle tools' sudo env PATH="$FIXTURE/bin:$PATH" MOCK_LOG="$FIXTURE/operations.log" "$ROOT/deploy/acm-deploy.sh" --repository-dir "$FIXTURE/repo" initial "$REV"
[ "$(sudo stat -c '%u:%g:%a' /run/lock)" = "$before_lock" ] || fail 'initial modified global /run/lock'
[ "$(owner "$FIXTURE/data")" = 10001:10001 ] && [ "$(mode "$FIXTURE/data")" = 750 ] || fail 'data directory ownership or mode is unsafe'
pass 'initial preserves global /run/lock and data directory contract'
[ "$(mode /run/lock/acm)" = 700 ] && [ "$(mode /run/lock/acm/acm-operation.lock)" = 600 ] && [ "$(owner /run/lock/acm)" = 0:0 ] && [ "$(owner /run/lock/acm/acm-operation.lock)" = 0:0 ] || fail 'global lock ownership or modes are unsafe'
pass 'global lock has exact root ownership and modes'
sudo grep -Fxq 'phase=complete' "$FIXTURE/repo/.local/deploy/production-state.env" && sudo grep -Fxq 'status=completed' "$FIXTURE/repo/.local/deploy/production-state.env" || fail 'initial state is not complete'
grep -Fq 'docker compose ' "$FIXTURE/operations.log" && grep -Fq ' build' "$FIXTURE/operations.log" && grep -Fq ' up -d --wait' "$FIXTURE/operations.log" || fail 'initial did not build and start the stack'
for service in caddy server ramiel; do grep -Fq "ps -q $service" "$FIXTURE/operations.log" || fail "smoke did not inspect $service"; done
grep -Fq 'https://api.ownership.test/healthz' "$FIXTURE/operations.log" || fail 'smoke did not request the public API URL'
pass 'initial builds, starts, smokes three services, and checks the public URL without live Docker or network access'
if command -v flock >/dev/null 2>&1; then
  sudo flock /run/lock/acm/acm-operation.lock sleep 2 & HOLDER=$!
  expect_fail 'database helper contends with the global deployment lock' 'another ACM database operation is active' sudo env PATH="$FIXTURE/bin:$PATH" MOCK_LOG="$FIXTURE/operations.log" "$ROOT/deploy/acm-db.sh" --repository-dir "$FIXTURE/repo" backup --backup-root "$FIXTURE/backups"
  wait "$HOLDER"; pass 'production helpers contend on the global lock'
else
  printf 'ok - production helpers contend on the global lock # SKIP flock unavailable\n'
fi
sudo install -d -o root -g root -m 0700 "$FIXTURE/backups" "$FIXTURE/quarantine"
# The initial lifecycle records local state in the checkout. Track this retained
# fixture state so the backup path exercises its clean-checkout contract.
sudo git -C "$FIXTURE/repo" add -f .local/deploy/production-state.env
sudo git -C "$FIXTURE/repo" commit -qm 'record production state'
sudo sh -c "printf '%s\\n' 'backup database content' > '$FIXTURE/data/db.sqlite'"
sudo chown 10001:10001 "$FIXTURE/data/db.sqlite"
sudo chmod 0600 "$FIXTURE/data/db.sqlite"
backup_output=$(sudo env PATH="$FIXTURE/bin:$PATH" MOCK_LOG="$FIXTURE/operations.log" "$ROOT/deploy/acm-db.sh" --repository-dir "$FIXTURE/repo" backup --backup-root "$FIXTURE/backups") || fail 'production database backup failed'
backup_dir=${backup_output#BACKUP_DIR=}
sudo sh -c '
  [ -d "$1" ] && [ "$(stat -c %u:%g "$1")" = 0:0 ] && [ "$(stat -c %a "$1")" = 500 ] || exit 1
  for payload in "$1"/*; do
    [ "$(stat -c %u:%g "$payload")" = 0:0 ] && [ "$(stat -c %a "$payload")" = 400 ] || exit 1
  done
' sh "$backup_dir" || fail 'backup payload does not have root ownership and sealed modes'
pass 'production backup seals root-owned payload files and directory'
sudo sh -c "printf '%s\\n' 'replacement database content' > '$FIXTURE/data/db.sqlite'"
sudo chown 10001:10001 "$FIXTURE/data/db.sqlite"
sudo chmod 0600 "$FIXTURE/data/db.sqlite"
expect_ok 'production database restore completes from root-owned backup' sudo env PATH="$FIXTURE/bin:$PATH" MOCK_LOG="$FIXTURE/operations.log" "$ROOT/deploy/acm-db.sh" --repository-dir "$FIXTURE/repo" restore --backup-dir "$backup_dir" --quarantine-root "$FIXTURE/quarantine" --yes-restore
[ "$(owner "$FIXTURE/data/db.sqlite")" = 10001:10001 ] && [ "$(mode "$FIXTURE/data/db.sqlite")" = 600 ] || fail 'restored database ownership or mode is unsafe'
[ "$(sudo sh -c "cat '$FIXTURE/data/db.sqlite'")" = 'backup database content' ] || fail 'restored database content differs from backup'
pass 'production restore normalizes data ownership, mode, and content'
sudo install -d -o root -g root -m 0755 "$FIXTURE/unsafe"
expect_fail 'production rejects unsafe fixture lock directory' 'operation lock directory must be mode 0700' sudo env ACM_DEPLOY_TEST_MODE=1 ACM_DEPLOY_REPO_ROOT="$FIXTURE/repo" ACM_DEPLOY_DATA_DIR="$FIXTURE/data" ACM_DEPLOY_STATE_DIR="$FIXTURE/state" ACM_DEPLOY_LOCK_PATH="$FIXTURE/unsafe/acm-operation.lock" ACM_DEPLOY_FLOCK_BIN=flock "$ROOT/deploy/acm-deploy.sh" rollback-start --backup "$FIXTURE/no-backup"

printf '1..%s # retained fixture: %s\n' "$PASS" "$FIXTURE"
