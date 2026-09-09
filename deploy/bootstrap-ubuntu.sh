#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEFAULT_REPOSITORY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly MARKER_NAME=.acm-managed
readonly MARKER_VERSION=acm-managed-v1
BOOTSTRAP_CONF=/etc/acm/bootstrap.conf
LOCK_PATH=/run/lock/acm/acm-operation.lock
LOCK_RUN_DIR=/run
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
TEST_MODE=${ACM_BOOTSTRAP_TEST_MODE:-0}
case "$TEST_MODE" in 0|1) ;; *) printf '%s\n' 'error: ACM_BOOTSTRAP_TEST_MODE must be 0 or 1' >&2; exit 1 ;; esac
if [ "$TEST_MODE" = 0 ]; then
  while IFS= read -r bootstrap_variable; do
    case "$bootstrap_variable" in ACM_BOOTSTRAP_TEST_*) printf '%s\n' 'error: ACM_BOOTSTRAP_TEST_* overrides require ACM_BOOTSTRAP_TEST_MODE=1' >&2; exit 1 ;; esac
  done < <(compgen -e)
fi
TEST_ROOT=${ACM_BOOTSTRAP_TEST_ROOT:-}
TEST_RUNNER=${ACM_BOOTSTRAP_TEST_RUNNER:-}
TEST_ENV_FILE=${ACM_BOOTSTRAP_TEST_ENV_FILE:-}
if [ "$TEST_MODE" = 1 ]; then
  [[ "$TEST_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] && [ "$TEST_ROOT" != / ] && [[ "$TEST_ROOT" != *//* && "$TEST_ROOT" != */./* && "$TEST_ROOT" != */../* && "$TEST_ROOT" != */. && "$TEST_ROOT" != */.. && "$TEST_ROOT" != */ ]] && [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] || fail 'test root must be a normalized existing non-symlink path other than /'
  [ -x "$TEST_RUNNER" ] && [ ! -L "$TEST_RUNNER" ] || fail 'test runner must be an executable non-symlink path'
  [ -z "$TEST_ENV_FILE" ] || { [[ "$TEST_ENV_FILE" == "$TEST_ROOT"/* ]] && [ -f "$TEST_ENV_FILE" ] && [ ! -L "$TEST_ENV_FILE" ]; } || fail 'test environment file must be a regular non-symlink below test root'
  BOOTSTRAP_CONF="$TEST_ROOT/etc/acm/bootstrap.conf"
  LOCK_RUN_DIR="$TEST_ROOT/run"
  LOCK_PATH="$LOCK_RUN_DIR/lock/acm/acm-operation.lock"
fi

check_only=0; configure_firewall_requested=0; adopt_existing_paths=0; enable_backups=0; verified_backup=''

usage() {
  printf '%s\n' \
    "Usage: ${0##*/} [--check|--dry-run] [--adopt-existing-paths] [--configure-firewall]" \
    "       ${0##*/} --enable-backups --verified-backup PATH" \
    '' \
    'All host paths are validated before bootstrap changes. Firewall configuration is' \
    'opt-in. Bootstrap installs, but never enables, the backup timer. Existing' \
    'nonempty managed directories need --adopt-existing-paths after review.'
}
canonicalize_path() {
  local path=$1 part
  local -a parts=() normalized=()
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    case "$part" in ''|.) ;; ..) fail "path traversal is not allowed: $path" ;; *) normalized+=("$part") ;; esac
  done
  (IFS=/; printf '/%s\n' "${normalized[*]}")
}

assert_absolute_literal_path() {
  local name=$1 path=$2 part current=/
  case "$path" in /*) ;; *) fail "$name must be an absolute path" ;; esac
  case "$path" in *[!A-Za-z0-9_./-]*) fail "$name contains unsupported characters" ;; esac
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    case "$part" in ''|.) ;; ..) fail "$name must not contain path traversal" ;;
      *) current="${current%/}/$part"; [ ! -L "$current" ] || fail "$name must not contain symlink components: $current" ;; esac
  done
}

same_or_below() { [ "$1" = "$2" ] || [[ "$1" == "$2"/* ]]; }
paths_overlap() { same_or_below "$1" "$2" || same_or_below "$2" "$1"; }

assert_path_policy() {
  local name=$1 path=$2 root
  for root in /etc /usr /boot /run /dev /proc /sys /bin /sbin /lib /lib64; do
    same_or_below "$path" "$root" && fail "$name must not be in protected system path $root"
  done
  for root in / /var /var/lib /var/backups /home /root /opt /srv /mnt /media /tmp; do
    same_or_below "$root" "$path" && fail "$name must not be broad system path $root or its ancestor"
  done
  return 0
}

validate_path() {
  local name=$1 path=$2
  assert_absolute_literal_path "$name" "$path"
  path=$(canonicalize_path "$path")
  assert_path_policy "$name" "$path"
  printf '%s\n' "$path"
}

marker_content() { printf '%s:%s\n' "$MARKER_VERSION" "$1"; }
marker_for() { printf '%s/%s\n' "$1" "$MARKER_NAME"; }

preflight_managed_directory() {
  local role=$1 path=$2 owner=$3 marker entry expected
  marker=$(marker_for "$path"); expected=$(marker_content "$role")
  assert_absolute_literal_path "$role directory" "$path"
  assert_trusted_path_components "$role directory" "$path" "$owner"
  [ ! -L "$path" ] || fail "$role directory must not be a symlink"
  [ -e "$path" ] || return 0
  [ -d "$path" ] || fail "$role directory must be a directory"
  case "$role" in
    data) assert_managed_role_contract data "$path" 750 10001 10001 ;;
    backup|quarantine) assert_managed_role_contract "$role" "$path" 700 0 0 ;;
  esac
  [ ! -L "$marker" ] || fail "$role marker must not be a symlink"
  if [ -e "$marker" ]; then
    [ -f "$marker" ] || fail "$role marker must be a regular file"
    [ "$(<"$marker")" = "$expected" ] || fail "$role marker has the wrong version or role"
    return
  fi
  shopt -s nullglob dotglob
  local -a entries=("$path"/*)
  shopt -u nullglob dotglob
  [ "${#entries[@]}" -eq 0 ] || [ "$adopt_existing_paths" -eq 1 ] || fail "$role directory is nonempty and unmarked; use --adopt-existing-paths to adopt it"
}

assert_managed_paths() {
  local path
  for path in "$data_dir" "$backup_dir" "$quarantine_dir"; do
    assert_absolute_literal_path "managed directory" "$path"
    paths_overlap "$path" "$repository_dir" && fail "managed paths must not overlap ACM_REPOSITORY_DIR"
  done
  paths_overlap "$data_dir" "$backup_dir" && fail "data and backup paths must not overlap"
  paths_overlap "$data_dir" "$quarantine_dir" && fail "data and quarantine paths must not overlap"
  paths_overlap "$backup_dir" "$quarantine_dir" && fail "backup and quarantine paths must not overlap"
  preflight_managed_directory data "$data_dir" 10001; preflight_managed_directory backup "$backup_dir" 0; preflight_managed_directory quarantine "$quarantine_dir" 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check|--dry-run) check_only=1 ;;
    --adopt-existing-paths) adopt_existing_paths=1 ;;
    --configure-firewall) configure_firewall_requested=1 ;;
    --enable-backups) enable_backups=1 ;;
    --verified-backup) shift; [ "$#" -gt 0 ] || fail "--verified-backup requires PATH"; verified_backup=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

stat_uid() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
stat_gid() { stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1"; }
stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
require_root_owned_safe_file() {
  local path=$1 mode
  [ -f "$path" ] && [ ! -L "$path" ] || fail "required file is not a regular non-symlink: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 0 ] && [ "$(stat_gid "$path")" = 0 ] || fail "required file is not owned by root:root: $path"
  fi
  mode=$(stat_mode "$path")
  [[ "$mode" =~ ^[0-7]+$ ]] || fail "invalid file mode: $path"
  [ $((8#$mode & 0022)) -eq 0 ] || fail "required file is group- or world-writable: $path"
}
require_safe_root_directory() {
  local path=$1 exact_mode=${2:-} mode
  [ -d "$path" ] && [ ! -L "$path" ] || fail "required directory is not a real non-symlink directory: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 0 ] && [ "$(stat_gid "$path")" = 0 ] || fail "required directory is not owned by root:root: $path"
  fi
  mode=$(stat_mode "$path")
  [[ "$mode" =~ ^[0-7]+$ ]] || fail "invalid directory mode: $path"
  if [ -n "$exact_mode" ]; then
    [ "$mode" = "$exact_mode" ] || fail "required directory must be mode 0$exact_mode: $path"
  else
    [ $((8#$mode & 0022)) -eq 0 ] || fail "required directory is group- or world-writable: $path"
  fi
}
require_root_owned_private_file() {
  local path=$1 mode
  [ -f "$path" ] && [ ! -L "$path" ] || fail "required file is not a regular non-symlink: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 0 ] && [ "$(stat_gid "$path")" = 0 ] || fail "required file is not owned by root:root: $path"
  fi
  mode=$(stat_mode "$path")
  case "$mode" in *[!0-7]*|'') fail "invalid file mode: $path" ;; esac
  [ "$mode" = 600 ] || fail "required file must be mode 0600: $path"
}

assert_trusted_path_components() {
  local name=$1 path=$2 final_owner=$3 part current=/ uid gid mode index=0 count
  IFS=/ read -r -a parts <<< "${path#/}"
  count=${#parts[@]}
  for part in "${parts[@]}"; do
    case "$part" in ''|.) continue ;; esac
    index=$((index + 1))
    current="${current%/}/$part"
    [ ! -L "$current" ] || fail "$name must not contain symlink components: $current"
    [ -e "$current" ] || continue
    [ "$index" -eq "$count" ] || [ -d "$current" ] || fail "$name has a non-directory ancestor: $current"
    uid=$(stat_uid "$current"); gid=$(stat_gid "$current"); mode=$(stat_mode "$current")
    [ $((8#$mode & 0022)) -eq 0 ] || fail "$name has a group- or world-writable component: $current"
    if [ "$TEST_MODE" != 1 ]; then
      if [ "$current" = "$path" ]; then
        [ "$uid" = 0 ] || [ "$uid" = "$final_owner" ] || fail "$name is not owned by root or its managed owner: $current"
      else
        [ "$uid" = 0 ] && [ "$gid" = 0 ] || fail "$name has a non-root-owned ancestor: $current"
      fi
    fi
  done
}

assert_managed_role_contract() {
  local role=$1 path=$2 expected_mode=$3 expected_uid=$4 expected_gid=$5
  assert_trusted_path_components "$role directory" "$path" "$expected_uid"
  [ -d "$path" ] && [ ! -L "$path" ] || fail "$role directory must be a real non-symlink directory"
  [ "$(stat_mode "$path")" = "$expected_mode" ] || fail "$role directory must be mode 0$expected_mode: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = "$expected_uid" ] && [ "$(stat_gid "$path")" = "$expected_gid" ] || fail "$role directory has the wrong owner: $path"
  fi
}

load_bootstrap_conf() {
  local line key value seen_repo=0 seen_backup=0 seen_quarantine=0
  require_root_owned_private_file "$BOOTSTRAP_CONF"
  repository_dir=''; backup_dir=''; quarantine_dir=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ACM_REPOSITORY_DIR=*) key=ACM_REPOSITORY_DIR; value=${line#*=}; [ "$seen_repo" -eq 0 ] || fail "duplicate ACM_REPOSITORY_DIR"; seen_repo=1; repository_dir=$value ;;
      ACM_BACKUP_DIR=*) key=ACM_BACKUP_DIR; value=${line#*=}; [ "$seen_backup" -eq 0 ] || fail "duplicate ACM_BACKUP_DIR"; seen_backup=1; backup_dir=$value ;;
      ACM_QUARANTINE_DIR=*) key=ACM_QUARANTINE_DIR; value=${line#*=}; [ "$seen_quarantine" -eq 0 ] || fail "duplicate ACM_QUARANTINE_DIR"; seen_quarantine=1; quarantine_dir=$value ;;
      *) fail "unknown or malformed bootstrap configuration entry" ;;
    esac
    [ -n "$value" ] || fail "$key must not be empty"
  done < "$BOOTSTRAP_CONF"
  [ "$seen_repo" -eq 1 ] && [ "$seen_backup" -eq 1 ] && [ "$seen_quarantine" -eq 1 ] || fail "bootstrap configuration is incomplete"
  repository_dir=$(validate_path ACM_REPOSITORY_DIR "$repository_dir")
  backup_dir=$(validate_path ACM_BACKUP_DIR "$backup_dir")
  quarantine_dir=$(validate_path ACM_QUARANTINE_DIR "$quarantine_dir")
}

parse_production_data_dir() {
  local env_file=$1 line value='' first last double_quote single_quote seen=0
  require_root_owned_private_file "$env_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ACM_DATA_DIR=*) [ "$seen" -eq 0 ] || fail "duplicate ACM_DATA_DIR in production environment"; seen=1; value=${line#ACM_DATA_DIR=} ;;
    esac
  done < "$env_file"
  [ "$seen" -eq 1 ] || fail "ACM_DATA_DIR is required in $env_file"
  printf -v double_quote '%b' '\042'; printf -v single_quote '%b' '\047'
  first=${value:0:1}; last=${value: -1}
  if [ "$first" = "$double_quote" ]; then
    [ "${#value}" -gt 1 ] && [ "$last" = "$double_quote" ] || fail "malformed double-quoted ACM_DATA_DIR"
    value=${value:1:${#value}-2}
  elif [ "$first" = "$single_quote" ]; then
    [ "${#value}" -gt 1 ] && [ "$last" = "$single_quote" ] || fail "malformed single-quoted ACM_DATA_DIR"
    value=${value:1:${#value}-2}
  fi
  [[ "$value" != *"$double_quote"* && "$value" != *"$single_quote"* ]] || fail "malformed quoted ACM_DATA_DIR"
  validate_path ACM_DATA_DIR "$value"
}

validate_repository() {
  local tracked absolute
  assert_absolute_literal_path ACM_REPOSITORY_DIR "$repository_dir"
  [ -d "$repository_dir" ] && [ ! -L "$repository_dir" ] || fail "ACM_REPOSITORY_DIR does not exist or is a symlink"
  assert_trusted_path_components ACM_REPOSITORY_DIR "$repository_dir" 0
  require_safe_root_directory "$repository_dir/.git"
  require_safe_root_directory "$repository_dir/deploy"
  require_safe_root_directory "$repository_dir/migrations"
  require_root_owned_safe_file "$repository_dir/deploy/acm-db.sh"
  require_root_owned_safe_file "$repository_dir/deploy/acm-deploy.sh"
  require_root_owned_safe_file "$repository_dir/deploy/smoke.sh"
  require_root_owned_safe_file "$repository_dir/compose.production.yml"
  git -C "$repository_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "ACM_REPOSITORY_DIR is not a Git checkout"
  while IFS= read -r -d '' tracked; do
    [[ "$tracked" != /* && "$tracked" != *'..'* ]] || fail "unsafe tracked repository path: $tracked"
    absolute="$repository_dir/$tracked"
    assert_trusted_path_components "tracked repository content" "$absolute" 0
    [ -f "$absolute" ] && [ ! -L "$absolute" ] || fail "tracked repository content is not a regular non-symlink file: $absolute"
    require_root_owned_safe_file "$absolute"
  done < <(git -C "$repository_dir" ls-files -z)
  [ -z "$(git -C "$repository_dir" status --porcelain --untracked-files=all)" ] || fail "ACM_REPOSITORY_DIR must be a clean checkout"
  [ -x "$repository_dir/deploy/acm-db.sh" ] && [ ! -L "$repository_dir/deploy/acm-db.sh" ] || fail "acm-db.sh is missing or unsafe"
  [ -x "$repository_dir/deploy/acm-deploy.sh" ] && [ ! -L "$repository_dir/deploy/acm-deploy.sh" ] || fail "acm-deploy.sh is missing or unsafe"
  [ -x "$repository_dir/deploy/smoke.sh" ] && [ ! -L "$repository_dir/deploy/smoke.sh" ] || fail "smoke.sh is missing or unsafe"
  [ -f "$repository_dir/compose.production.yml" ] && [ ! -L "$repository_dir/compose.production.yml" ] || fail "production Compose file is missing or unsafe"
  [ -f "$SCRIPT_DIR/systemd/acm-db-backup@.service" ] && [ -f "$SCRIPT_DIR/systemd/acm-db-backup@.timer" ] || fail "backup unit template is missing"
}

validate_host() {
  [ "$TEST_MODE" = 1 ] && return
  [ "$(uname -m)" = x86_64 ] || fail "this bootstrap supports Ubuntu x86-64 hosts only"
  [ -r /etc/os-release ] || fail "unable to identify the host operating system"; . /etc/os-release
  [ "${ID:-}" = ubuntu ] || fail "this bootstrap supports Ubuntu hosts only"
  [ "$(dpkg --print-architecture)" = amd64 ] || fail "this bootstrap supports Ubuntu amd64 hosts only"
}
set_root_runner() { [ "$TEST_MODE" = 1 ] && { SUDO=(); return; }; if [ "$(id -u)" -eq 0 ]; then SUDO=(); else command -v sudo >/dev/null 2>&1 || fail "run as root or install sudo"; sudo -v; SUDO=(sudo); fi; }
run_root() { [ "$TEST_MODE" = 1 ] && { "$TEST_RUNNER" "$@"; return; }; "${SUDO[@]}" "$@"; }
write_bootstrap_conf() { printf 'ACM_REPOSITORY_DIR=%s\nACM_BACKUP_DIR=%s\nACM_QUARANTINE_DIR=%s\n' "$repository_dir" "$backup_dir" "$quarantine_dir" | run_root tee "$BOOTSTRAP_CONF" >/dev/null; run_root chown root:root "$BOOTSTRAP_CONF"; run_root chmod 0600 "$BOOTSTRAP_CONF"; }

mark_directory() {
  local role=$1 path=$2 mode=$3 owner=$4 group=$5 marker
  marker=$(marker_for "$path")
  # Recheck immediately before changing directory metadata or creating a marker.
  preflight_managed_directory "$role" "$path" "$owner"
  run_root install -d -m "$mode" -o "$owner" -g "$group" "$path"
  [ -e "$marker" ] || marker_content "$role" | run_root install -m 0644 -o root -g root /dev/stdin "$marker"
}

install_docker() {
  run_root apt-get update; run_root apt-get install -y ca-certificates curl gnupg ufw
  run_root install -d -m 0755 /etc/apt/keyrings; run_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; run_root chmod a+r /etc/apt/keyrings/docker.asc
  printf '%s\n' "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  run_root apt-get update; run_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
install_units() {
  run_root install -d -m 0755 /usr/local/libexec/acm
  run_root install -m 0755 "$repository_dir/deploy/acm-deploy.sh" /usr/local/libexec/acm/acm-deploy.sh
  run_root install -m 0755 "$repository_dir/deploy/acm-db.sh" /usr/local/libexec/acm/acm-db.sh
  run_root install -m 0755 "$repository_dir/deploy/smoke.sh" /usr/local/libexec/acm/smoke.sh
  run_root install -m 0644 "$SCRIPT_DIR/systemd/acm-db-backup@.service" /etc/systemd/system/acm-db-backup@.service
  run_root install -m 0644 "$SCRIPT_DIR/systemd/acm-db-backup@.timer" /etc/systemd/system/acm-db-backup@.timer
  run_root systemctl daemon-reload
}
prepare_lock() {
  local lock_dir
  require_safe_root_directory "$LOCK_RUN_DIR"
  require_safe_root_directory "$LOCK_RUN_DIR/lock"
  lock_dir=$(dirname -- "$LOCK_PATH")
  if [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
    run_root mkdir -m 0700 -- "$lock_dir" 2>/dev/null || true
  fi
  require_safe_root_directory "$lock_dir" 700
  [ "$TEST_MODE" = 1 ] || [ "$(stat_gid "$lock_dir")" = 0 ] || fail "operation lock directory is not root-group-owned: $lock_dir"
  if [ -e "$LOCK_PATH" ] || [ -L "$LOCK_PATH" ]; then
    [ -f "$LOCK_PATH" ] && [ ! -L "$LOCK_PATH" ] && { [ "$TEST_MODE" = 1 ] || [ "$(stat_uid "$LOCK_PATH")" = 0 ]; } && { [ "$TEST_MODE" = 1 ] || [ "$(stat_gid "$LOCK_PATH")" = 0 ]; } && [ "$(stat_mode "$LOCK_PATH")" = 600 ] || fail "operation lock must be root-owned regular mode 0600: $LOCK_PATH"
  else
    run_root sh -c 'umask 077; set -C; : > "$1"' sh "$LOCK_PATH" 2>/dev/null || true
    [ -f "$LOCK_PATH" ] && [ ! -L "$LOCK_PATH" ] && [ "$(stat_mode "$LOCK_PATH")" = 600 ] || fail "could not create operation lock: $LOCK_PATH"
  fi
  [ "$TEST_MODE" = 1 ] || [ "$(stat_uid "$LOCK_PATH")" = 0 ] || fail "operation lock is not root-owned: $LOCK_PATH"
  [ "$TEST_MODE" = 1 ] || [ "$(stat_gid "$LOCK_PATH")" = 0 ] || fail "operation lock is not root-group-owned: $LOCK_PATH"
}
configure_firewall() { run_root ufw allow 22/tcp; run_root ufw allow 80/tcp; run_root ufw allow 443/tcp; run_root ufw default deny incoming; run_root ufw default allow outgoing; run_root ufw --force enable; }

if [ "$enable_backups" -eq 1 ]; then
  [ "$check_only" -eq 0 ] && [ "$configure_firewall_requested" -eq 0 ] && [ "$adopt_existing_paths" -eq 0 ] && [ -n "$verified_backup" ] || fail "--enable-backups requires only --verified-backup PATH"
  unset ACM_REPOSITORY_DIR ACM_DATA_DIR ACM_BACKUP_DIR ACM_QUARANTINE_DIR
  load_bootstrap_conf
  validate_repository
  data_dir=$(parse_production_data_dir "${TEST_ENV_FILE:-$repository_dir/deploy/.env.production}")
  assert_managed_paths
  [ -d "$data_dir" ] && [ ! -L "$data_dir" ] && [ -f "$data_dir/db.sqlite" ] && [ ! -L "$data_dir/db.sqlite" ] || fail "production SQLite database is missing or unsafe"
  verified_backup=$(validate_path verified_backup "$verified_backup")
  same_or_below "$verified_backup" "$backup_dir" || fail "verified backup must be inside ACM_BACKUP_DIR"
  [ -d "$verified_backup" ] && [ ! -L "$verified_backup" ] || fail "verified backup must be an existing non-symlink directory"
  grep -Fq -- '--repository-dir' "$repository_dir/deploy/acm-db.sh" || fail "backup helper lacks --repository-dir support"
  grep -Fq -- 'acm-db.sh --repository-dir ${ACM_REPOSITORY_DIR} backup --backup-root ${ACM_BACKUP_DIR}' "$SCRIPT_DIR/systemd/acm-db-backup@.service" || fail "backup service contract is invalid"
  run_root systemctl is-active --quiet acm-db-backup@daily.timer && fail "backup timer is already active"
  "$repository_dir/deploy/acm-db.sh" --repository-dir "$repository_dir" verify --backup-dir "$verified_backup"
  validate_host; set_root_runner; install_units; run_root systemctl enable --now acm-db-backup@daily.timer
  printf 'backups enabled\n'; exit 0
fi

repository_dir=$(validate_path ACM_REPOSITORY_DIR "${ACM_REPOSITORY_DIR:-$DEFAULT_REPOSITORY_DIR}")
data_dir=$(validate_path ACM_DATA_DIR "${ACM_DATA_DIR:-/var/lib/acm}")
backup_dir=$(validate_path ACM_BACKUP_DIR "${ACM_BACKUP_DIR:-/var/backups/acm}")
quarantine_dir=$(validate_path ACM_QUARANTINE_DIR "${ACM_QUARANTINE_DIR:-/var/lib/acm-quarantine}")
validate_repository; assert_managed_paths
if [ "$check_only" -eq 1 ]; then printf 'check passed: inputs and managed-directory state are valid; no host changes made\n'; exit 0; fi
validate_host; set_root_runner
# Recheck every mutable path after privilege acquisition and before package/filesystem/systemd work.
validate_repository; assert_managed_paths
install_docker
mark_directory data "$data_dir" 0750 10001 10001; mark_directory backup "$backup_dir" 0700 root root; mark_directory quarantine "$quarantine_dir" 0700 root root
prepare_lock
run_root install -d -m 0755 /etc/acm
write_bootstrap_conf
[ "$configure_firewall_requested" -eq 1 ] && configure_firewall
install_units
printf 'bootstrap complete; backups remain disabled (run --enable-backups --verified-backup PATH after deployment)\n'
