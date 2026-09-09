#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
FIXTURE=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/tmp}/acm-bootstrap-apply.XXXXXX")" && pwd -P)
LOG=$FIXTURE/runner.log
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
expect() { "$@" || fail "command failed: $*"; }
expect_output() { local expected=$1; shift; local output; output=$("$@") || fail "command failed: $*"; [ "$output" = "$expected" ] || fail "unexpected output: $output"; }

mkdir -p "$FIXTURE/repo/deploy" "$FIXTURE/repo/migrations" "$FIXTURE/data" "$FIXTURE/backups" "$FIXTURE/quarantine" "$FIXTURE/run/acm"
chmod 0750 "$FIXTURE/data"
chmod 0700 "$FIXTURE/backups" "$FIXTURE/quarantine"
chmod 0700 "$FIXTURE/run/acm"
cp "$ROOT/deploy/acm-deploy.sh" "$ROOT/deploy/acm-db.sh" "$ROOT/deploy/smoke.sh" "$FIXTURE/repo/deploy/"
cp -R "$ROOT/deploy/systemd" "$FIXTURE/bootstrap-systemd"
printf 'services: {}\n' > "$FIXTURE/repo/compose.production.yml"
printf 'ACM_DATA_DIR=%s/data\n' "$FIXTURE" > "$FIXTURE/repo/deploy/production.env"
chmod 0600 "$FIXTURE/repo/deploy/production.env"
printf 'select 1;\n' > "$FIXTURE/repo/migrations/001.sql"
git -C "$FIXTURE/repo" init -q
git -C "$FIXTURE/repo" config user.email test@example.invalid
git -C "$FIXTURE/repo" config user.name test
git -C "$FIXTURE/repo" add . && git -C "$FIXTURE/repo" commit -qm fixture

cat > "$FIXTURE/runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
root=${ACM_BOOTSTRAP_TEST_ROOT:?}
log=${ACM_BOOTSTRAP_TEST_LOG:?}
printf '%q ' "$@" >> "$log"; printf '\n' >> "$log"
map_path() {
  case "$1" in
    "$root"/*) printf '%s\n' "$1" ;;
    /etc/*|/usr/*|/run/*) printf '%s%s\n' "$root" "$1" ;;
    *) printf 'runner rejected destination: %s\n' "$1" >&2; exit 64 ;;
  esac
}
case "$1" in
  apt-get|ufw) exit 0 ;;
  curl)
    for ((i=1; i <= $#; i++)); do [ "${!i}" = -o ] && { j=$((i + 1)); target=$(map_path "${!j}"); mkdir -p "$(dirname -- "$target")"; : > "$target"; exit 0; }; done
    exit 64 ;;
  systemctl)
    case "${2:-}" in is-active) exit 3 ;; daemon-reload|enable) exit 0 ;; *) exit 64 ;; esac ;;
  chown) exit 0 ;;
  chmod)
    target=$(map_path "${!#}"); command chmod "$2" "$target" ;;
  tee)
    target=$(map_path "${!#}"); mkdir -p "$(dirname -- "$target")"; command tee "$target" ;;
  install)
    args=() skip=0
    for arg in "${@:2}"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$arg" in -o|-g) skip=1 ;; *) args+=("$arg") ;; esac
    done
    last=$((${#args[@]} - 1)); args[$last]=$(map_path "${args[$last]}")
    if [ "${args[$((last - 1))]}" = /dev/stdin ]; then
      mode=0755
      for ((i=0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = -m ] && mode=${args[$((i + 1))]}; done
      command cat > "${args[$last]}"; command chmod "$mode" "${args[$last]}"; exit 0
    fi
    case " ${args[*]} " in
      *' -d '*) command install "${args[@]}"; exit 0 ;;
    esac
    mode=0755
    for ((i=0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = -m ] && mode=${args[$((i + 1))]}; done
    command mkdir -p "$(dirname -- "${args[$last]}")"
    command cp "${args[$((last - 1))]}" "${args[$last]}"
    command chmod "$mode" "${args[$last]}"
    exit 0
    ;;
  sh)
    target=$(map_path "${!#}")
    command sh "$2" "$3" "$4" "$target"
    ;;
  *) printf 'runner rejected command: %s\n' "$1" >&2; exit 64 ;;
esac
RUNNER
chmod 0755 "$FIXTURE/runner"

common=(env UBUNTU_CODENAME=jammy ACM_BOOTSTRAP_TEST_MODE=1 ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE" ACM_BOOTSTRAP_TEST_RUNNER="$FIXTURE/runner" ACM_BOOTSTRAP_TEST_ENV_FILE="$FIXTURE/repo/deploy/production.env" ACM_BOOTSTRAP_TEST_LOG="$LOG" ACM_DB_TEST_MODE=1 ACM_ENV_FILE="$FIXTURE/repo/deploy/production.env" ACM_DOCKER_BIN="$FIXTURE/docker" ACM_FLOCK_BIN="$FIXTURE/flock" ACM_DB_LOCK_PATH="$FIXTURE/db.lock" ACM_REPOSITORY_DIR="$FIXTURE/repo" ACM_DATA_DIR="$FIXTURE/data" ACM_BACKUP_DIR="$FIXTURE/backups" ACM_QUARANTINE_DIR="$FIXTURE/quarantine" "$ROOT/deploy/bootstrap-ubuntu.sh")
set +e
invalid_root_output=$(env ACM_BOOTSTRAP_TEST_MODE=1 ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE//" "$ROOT/deploy/bootstrap-ubuntu.sh" --help 2>&1)
invalid_root_status=$?
set -e
[ "$invalid_root_status" -ne 0 ] && [[ "$invalid_root_output" == *'error: test root must be a normalized existing non-symlink path other than /'* ]] && [[ "$invalid_root_output" != *'command not found'* ]] || fail 'invalid gated test root did not report the intended error'
pass 'gated invalid test root reports intended error'
if env ACM_BOOTSTRAP_TEST_ROOT="$FIXTURE" "$ROOT/deploy/bootstrap-ubuntu.sh" --help >/dev/null 2>&1; then fail 'production accepted test override'; fi
pass 'production rejects test overrides without gate'

expect_output 'bootstrap complete; backups remain disabled (run --enable-backups --verified-backup PATH after deployment)' "${common[@]}"
pass 'ordinary apply emits exact completion output'
config=$FIXTURE/etc/acm/bootstrap.conf
[ -f "$config" ] && [ ! -L "$config" ] && [ "$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config")" = 600 ] || fail 'bootstrap config is not regular mode 0600'
expected=$(printf 'ACM_REPOSITORY_DIR=%s\nACM_BACKUP_DIR=%s\nACM_QUARANTINE_DIR=%s' "$FIXTURE/repo" "$FIXTURE/backups" "$FIXTURE/quarantine")
[ "$(<"$config")" = "$expected" ] || fail 'bootstrap config values differ'
pass 'ordinary apply writes exact private bootstrap config'
for role_path in "$FIXTURE/data:data" "$FIXTURE/backups:backup" "$FIXTURE/quarantine:quarantine"; do path=${role_path%%:*}; role=${role_path#*:}; [ "$(<"$path/.acm-managed")" = "acm-managed-v1:$role" ] || fail "missing $role marker"; done
pass 'ordinary apply writes managed role markers'
[ "$(stat -c '%a' "$FIXTURE/data" 2>/dev/null || stat -f '%Lp' "$FIXTURE/data")" = 750 ] && [ "$(stat -c '%a' "$FIXTURE/backups" 2>/dev/null || stat -f '%Lp' "$FIXTURE/backups")" = 700 ] && [ "$(stat -c '%a' "$FIXTURE/quarantine" 2>/dev/null || stat -f '%Lp' "$FIXTURE/quarantine")" = 700 ] || fail 'bootstrap managed directory modes differ from role contracts'
pass 'ordinary apply preserves managed role modes'
[ -d "$FIXTURE/run/acm" ] && [ ! -L "$FIXTURE/run/acm" ] && [ "$(stat -c '%a' "$FIXTURE/run/acm" 2>/dev/null || stat -f '%Lp' "$FIXTURE/run/acm")" = 700 ] || fail 'bootstrap lock directory is not mode 0700'
[ -f "$FIXTURE/run/acm/acm-operation.lock" ] && [ ! -L "$FIXTURE/run/acm/acm-operation.lock" ] && [ "$(stat -c '%a' "$FIXTURE/run/acm/acm-operation.lock" 2>/dev/null || stat -f '%Lp' "$FIXTURE/run/acm/acm-operation.lock")" = 600 ] || fail 'bootstrap lock is not regular mode 0600'
pass 'ordinary apply creates the private operation lock directory and lock'
grep -Fq 'install -m 0755' "$LOG" && grep -Fq 'acm-deploy.sh' "$LOG" && grep -Fq 'acm-db.sh' "$LOG" && grep -Fq 'smoke.sh' "$LOG" || fail 'stable helper installs missing'
! grep -Fq 'enable --now acm-db-backup@daily.timer' "$LOG" || fail 'ordinary apply enabled timer'
pass 'ordinary apply installs stable helpers without enabling timer or escaping test root'

docker=$FIXTURE/docker
flock=$FIXTURE/flock
printf 'database\n' > "$FIXTURE/data/db.sqlite"
printf '#!/usr/bin/env bash\nexit 0\n' > "$docker"; chmod 0755 "$docker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$flock"; chmod 0755 "$flock"
backup=$(env ACM_DB_TEST_MODE=1 ACM_DATA_DIR="$FIXTURE/data" ACM_ENV_FILE="$FIXTURE/repo/deploy/production.env" ACM_DOCKER_BIN="$docker" ACM_FLOCK_BIN="$flock" ACM_DB_LOCK_PATH="$FIXTURE/db.lock" "$FIXTURE/repo/deploy/acm-db.sh" --repository-dir "$FIXTURE/repo" backup --backup-root "$FIXTURE/backups")
backup=${backup#BACKUP_DIR=}
[ -d "$backup" ] || fail 'real helper did not create verified backup'
[ "$(stat -c '%a' "$backup" 2>/dev/null || stat -f '%Lp' "$backup")" = 500 ] || fail 'verified backup directory is not mode 0500'
for payload in "$backup"/*; do [ "$(stat -c '%a' "$payload" 2>/dev/null || stat -f '%Lp' "$payload")" = 400 ] || fail "verified backup payload is not mode 0400: $payload"; done
pass 'real helper seals completed backup modes'
backup_before=$(cksum "$backup/metadata.txt" "$backup/manifest.sha256")
chmod 0640 "$config"
if "${common[@]}" --enable-backups --verified-backup "$backup" >/dev/null 2>&1; then fail 'enable-backups accepted mode 0640 config'; fi
pass 'enable-backups rejects non-0600 config'
chmod 0600 "$config"
expect_output 'backups enabled' "${common[@]}" --enable-backups --verified-backup "$backup"
pass 'enable-backups accepts same config and emits exact output'
[ "$backup_before" = "$(cksum "$backup/metadata.txt" "$backup/manifest.sha256")" ] || fail 'enable-backups mutated verified backup'
! grep -q '^ufw ' "$LOG" || fail 'backup enable invoked firewall'
grep -Fq 'systemctl is-active --quiet acm-db-backup@daily.timer' "$LOG" && grep -Fq 'systemctl enable --now acm-db-backup@daily.timer' "$LOG" || fail 'backup timer transitions missing'
pass 'enable-backups verifies backup, leaves it unchanged, and enables timer'
printf 'ok - retained fixture: %s\n' "$FIXTURE"
