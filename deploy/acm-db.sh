#!/usr/bin/env bash
# SQLite backup and restore helper for the production Compose deployment.
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEFAULT_REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
repository_arg=""
remaining_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repository-dir)
      [ -z "$repository_arg" ] || { printf '%s\n' 'acm-db: duplicate --repository-dir' >&2; exit 1; }
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { printf '%s\n' 'acm-db: --repository-dir requires an absolute path' >&2; exit 1; }
      repository_arg="$2"
      shift 2
      ;;
    *) remaining_args+=("$1"); shift;;
  esac
done
set -- "${remaining_args[@]}"
readonly TEST_MODE="${ACM_DB_TEST_MODE:-0}"
case "$TEST_MODE" in 0|1) ;; *) printf '%s\n' 'acm-db: ACM_DB_TEST_MODE must be 0 or 1' >&2; exit 1;; esac
if [ "$TEST_MODE" = 0 ]; then
  [ -z "${ACM_DATA_DIR+x}" ] || { printf '%s\n' 'acm-db: ACM_DATA_DIR override requires ACM_DB_TEST_MODE=1' >&2; exit 1; }
  [ -z "${ACM_ENV_FILE+x}" ] || { printf '%s\n' 'acm-db: ACM_ENV_FILE override requires ACM_DB_TEST_MODE=1' >&2; exit 1; }
  [ -z "${ACM_DOCKER_BIN+x}" ] || { printf '%s\n' 'acm-db: command overrides require ACM_DB_TEST_MODE=1' >&2; exit 1; }
  [ -z "${ACM_COMPOSE_FILE+x}" ] || { printf '%s\n' 'acm-db: command overrides require ACM_DB_TEST_MODE=1' >&2; exit 1; }
  [ -z "${ACM_DB_LOCK_PATH+x}" ] || { printf '%s\n' 'acm-db: lock overrides require ACM_DB_TEST_MODE=1' >&2; exit 1; }
  [ -z "${ACM_FLOCK_BIN+x}" ] || { printf '%s\n' 'acm-db: command overrides require ACM_DB_TEST_MODE=1' >&2; exit 1; }
fi
effective_uid() { if [ "$TEST_MODE" = 1 ]; then printf '%s\n' "${ACM_DB_TEST_EUID:-0}"; else id -u; fi; }
require_root() { [ "$(effective_uid)" = 0 ] || die "backup and restore require effective UID 0"; }
if [ -n "$repository_arg" ]; then
  readonly REPO_DIR="$repository_arg"
else
  readonly REPO_DIR="$DEFAULT_REPO_DIR"
fi
readonly ENV_FILE="${ACM_ENV_FILE:-$REPO_DIR/deploy/.env.production}"
readonly COMPOSE_FILE="${ACM_COMPOSE_FILE:-$REPO_DIR/compose.production.yml}"
readonly DOCKER_BIN="${ACM_DOCKER_BIN:-docker}"
readonly LOCK_PATH="${ACM_DB_LOCK_PATH:-/run/lock/acm/acm-operation.lock}"
readonly FLOCK_BIN="${ACM_FLOCK_BIN:-flock}"
readonly DB_NAMES=(db.sqlite db.sqlite-wal db.sqlite-shm)

dry_run=false
stopped_by_us=false
restore_quarantine=""
lock_held=false
VERIFIED_SOURCE_REVISION=""
VERIFIED_MIGRATION_IDENTITY=""

usage() {
  printf '%s\n' "Usage:
  $0 backup --backup-root PATH [--dry-run]
  $0 verify --backup-dir PATH
  $0 restore --backup-dir PATH --yes-restore [--quarantine-root PATH] [--dry-run]

  $0 metadata --backup-dir PATH

Testing overrides require ACM_DB_TEST_MODE=1. --dry-run makes no changes."
}

die() { printf 'acm-db: %s\n' "$*" >&2; exit 1; }
note() { printf 'acm-db: %s\n' "$*" >&2; }
stat_uid() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
stat_gid() { stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1"; }
stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

assert_safe_dir() {
  local path="$1" exact_mode="${2:-}" mode
  [ -d "$path" ] && [ ! -L "$path" ] || die "directory must be a real non-symlink directory: $path"
  mode="$(stat_mode "$path")"
  [[ "$mode" =~ ^[0-7]+$ ]] || die "invalid directory mode: $path"
  if [ -n "$exact_mode" ]; then
    [ "$mode" = "$exact_mode" ] || die "directory must be mode 0$exact_mode: $path"
  else
    [ $((8#$mode & 0022)) -eq 0 ] || die "directory is group- or world-writable: $path"
  fi
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 0 ] && [ "$(stat_gid "$path")" = 0 ] || die "directory is not owned by root:root: $path"
  fi
}

assert_safe_file() {
  local path="$1" exact_mode="${2:-}" mode
  [ -f "$path" ] && [ ! -L "$path" ] || die "file must be a regular non-symlink file: $path"
  mode="$(stat_mode "$path")"
  [[ "$mode" =~ ^[0-7]+$ ]] || die "invalid file mode: $path"
  if [ -n "$exact_mode" ]; then
    [ "$mode" = "$exact_mode" ] || die "file must be mode 0$exact_mode: $path"
  else
    [ $((8#$mode & 0022)) -eq 0 ] || die "file is group- or world-writable: $path"
  fi
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 0 ] && [ "$(stat_gid "$path")" = 0 ] || die "file is not owned by root:root: $path"
  fi
}

assert_trusted_ancestors() {
  local current
  # Walk upward so every existing parent is checked without relying on a
  # globally shared shell array while paths are being validated.
  current="$(dirname -- "$1")"
  while [ "$current" != / ]; do
    assert_safe_dir "$current"
    current="$(dirname -- "$current")"
  done
  assert_safe_dir /
}

assert_data_dir() {
  local path="$1"
  assert_trusted_ancestors "$path"
  [ -d "$path" ] && [ ! -L "$path" ] || die "data directory must be a real non-symlink directory: $path"
  [ "$(stat_mode "$path")" = 750 ] || die "data directory must be mode 0750: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 10001 ] && [ "$(stat_gid "$path")" = 10001 ] || die "data directory must be owned by 10001:10001: $path"
  fi
}

assert_private_root_dir() {
  local path="$1" role="$2"
  assert_trusted_ancestors "$path"
  [ -d "$path" ] && [ ! -L "$path" ] || die "$role must be a real non-symlink directory: $path"
  [ "$(stat_mode "$path")" = 700 ] || die "$role must be mode 0700: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 0 ] && [ "$(stat_gid "$path")" = 0 ] || die "$role must be owned by root:root: $path"
  fi
}

assert_backup_payload_dir() {
  local path="$1"
  assert_trusted_ancestors "$path"
  [ -d "$path" ] && [ ! -L "$path" ] || die "backup directory must be a real non-symlink directory: $path"
  [ "$(stat_mode "$path")" = 500 ] || die "completed backup directory must be mode 0500: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 0 ] && [ "$(stat_gid "$path")" = 0 ] || die "completed backup directory must be owned by root:root: $path"
  fi
}

assert_db_file() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] || die "database file must be a regular non-symlink file: $path"
  [ $((8#$(stat_mode "$path") & 0022)) -eq 0 ] || die "database file is group- or world-writable: $path"
  if [ "$TEST_MODE" = 0 ]; then
    [ "$(stat_uid "$path")" = 10001 ] && [ "$(stat_gid "$path")" = 10001 ] || die "database file must be owned by 10001:10001: $path"
  fi
}

canonical_dir() {
  [ -d "$1" ] || die "directory does not exist: $1"
  [ ! -L "$1" ] || die "symlink paths are not allowed: $1"
  (CDPATH= cd -- "$1" && pwd -P)
}

assert_operator_path() {
  local path="$1" part current=/
  case "$path" in /*) ;; *) die "path must be absolute: $path";; esac
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) continue;;
      ..) die "path traversal is not allowed: $path";;
    esac
    current="${current%/}/$part"
    [ ! -L "$current" ] || die "symlink paths are not allowed: $current"
  done
}

assert_no_symlink_components() {
  local path="$1" part current=""
  case "$path" in /*) current=/;; *) die "path must be absolute after resolution: $path";; esac
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    current="${current%/}/$part"
    [ ! -L "$current" ] || die "symlink paths are not allowed: $current"
  done
}

resolve_existing_dir() {
  local resolved
  assert_operator_path "$1"
  resolved="$(canonical_dir "$1")"
  assert_no_symlink_components "$resolved"
  printf '%s\n' "$resolved"
}

validate_repository() {
  local resolved worktree revision current=/ part migration tracked relative parent
  resolved="$(resolve_existing_dir "$REPO_DIR")"
  [ "$resolved" = "$REPO_DIR" ] || die "repository path must be normalized"
  IFS=/ read -r -a parts <<< "${REPO_DIR#/}"
  for part in "${parts[@]}"; do current="${current%/}/$part"; assert_safe_dir "$current"; done
  assert_safe_dir "$REPO_DIR/.git"
  assert_safe_dir "$REPO_DIR/deploy"
  assert_safe_dir "$REPO_DIR/migrations"
  worktree="$(git -C "$REPO_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" || die "repository is not a Git worktree"
  [ "$worktree" = true ] || die "repository is not a Git worktree"
  revision="$(git -C "$REPO_DIR" rev-parse --verify HEAD)" || die "could not determine source revision"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "source revision is not a full SHA-1"
  while IFS= read -r -d '' tracked; do
    [[ "$tracked" != /* && "$tracked" != *'..'* ]] || die "unsafe tracked path: $tracked"
    relative="$REPO_DIR/$tracked"
    parent="$(dirname -- "$relative")"
    assert_trusted_ancestors "$relative"
    [ -f "$relative" ] && [ ! -L "$relative" ] || die "tracked content must be a regular non-symlink file: $relative"
    assert_safe_file "$relative"
  done < <(git -C "$REPO_DIR" ls-files -z)
  assert_trusted_ancestors "$COMPOSE_FILE"; assert_safe_file "$COMPOSE_FILE"
  assert_trusted_ancestors "$ENV_FILE"; assert_safe_file "$ENV_FILE" 600
  validate_migrations
}

validate_migrations() {
  local node
  # -P is explicit: every node, including a symlink or special file, must be
  # inspected rather than followed or silently omitted by a type filter.
  while IFS= read -r -d '' node; do
    case "$node" in *$'\n'*) die "migration path contains a newline: $node";; esac
    if [ -d "$node" ] && [ ! -L "$node" ]; then
      assert_safe_dir "$node"
    elif [ -f "$node" ] && [ ! -L "$node" ]; then
      assert_safe_file "$node"
    else
      die "migration tree contains a nonregular or symlink entry: $node"
    fi
  done < <(find -P "$REPO_DIR/migrations" -print0)
}

data_dir_from_env_file() {
  local line value='' found=false
  [ ! -L "$ENV_FILE" ] || die "environment file must not be a symlink"
  [ -e "$ENV_FILE" ] || die "environment file is missing"
  [ -f "$ENV_FILE" ] || die "environment file is not a regular file"

  # Do not source dotenv files: only a literal final assignment is considered.
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ACM_DATA_DIR=*) value=${line#ACM_DATA_DIR=}; found=true;;
    esac
  done < "$ENV_FILE"
  if ! "$found"; then
    die "ACM_DATA_DIR is missing from environment file"
  fi

  case "$value" in
    \"*)
      [ "${#value}" -ge 2 ] && [ "${value: -1}" = '"' ] || die "malformed quoted ACM_DATA_DIR in environment file"
      value=${value:1:${#value}-2}
      ;;
    \')
      die "malformed quoted ACM_DATA_DIR in environment file"
      ;;
    \'*)
      [ "${#value}" -ge 2 ] && [ "${value: -1}" = "'" ] || die "malformed quoted ACM_DATA_DIR in environment file"
      value=${value:1:${#value}-2}
      ;;
    *\"*|*\'*)
      die "malformed quoted ACM_DATA_DIR in environment file"
      ;;
  esac
  [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "ACM_DATA_DIR in environment file must be an absolute, literal path"
  case "$value" in *//*|*/./*|*/../*|*/.|*/..|*/) die "ACM_DATA_DIR in environment file must be normalized";; esac
  printf '%s\n' "$value"
}

case "${1:-}" in -h|--help|help) usage; exit 0;; esac
validate_repository
if [ "$TEST_MODE" = 1 ] && [ -n "${ACM_DATA_DIR+x}" ] && [ -n "$ACM_DATA_DIR" ]; then
  readonly DATA_DIR_INPUT="$ACM_DATA_DIR"
else
  readonly DATA_DIR_INPUT="$(data_dir_from_env_file)"
fi

current_data_dir_input() {
  printf '%s\n' "$DATA_DIR_INPUT"
}

inside_or_same() {
  local parent="$1" child="$2"
  [ "$parent" = "$child" ] || [[ "$child" == "$parent"/* ]]
}

assert_separate() {
  local first="$1" second="$2"
  if inside_or_same "$first" "$second" || inside_or_same "$second" "$first"; then
    die "paths overlap: $first and $second"
  fi
}

filesystem_id() {
  stat -f '%d' "$1" 2>/dev/null || stat -c '%d' "$1"
}

acquire_lock() {
  local lock_dir
  command -v "$FLOCK_BIN" >/dev/null 2>&1 || die "flock is required for mutating database operations"
  assert_operator_path "$LOCK_PATH"
  lock_dir="$(dirname -- "$LOCK_PATH")"
  if [ "$TEST_MODE" = 0 ] || [ "$LOCK_PATH" = /run/lock/acm/acm-operation.lock ]; then
    assert_safe_dir /run
    assert_safe_dir /run/lock
  fi
  if [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
    (umask 077; mkdir -- "$lock_dir") 2>/dev/null || true
  fi
  assert_safe_dir "$lock_dir" 700
  if [ ! -e "$LOCK_PATH" ] && [ ! -L "$LOCK_PATH" ]; then
    (umask 077; set -C; : > "$LOCK_PATH") 2>/dev/null || true
  fi
  assert_safe_file "$LOCK_PATH" 600
  [ "$TEST_MODE" = 1 ] || [ "$(stat_gid "$LOCK_PATH")" = 0 ] || die "database operation lock is not root-group-owned: $LOCK_PATH"
  [ "$TEST_MODE" = 1 ] || [ "$(stat_gid "$lock_dir")" = 0 ] || die "database operation lock directory is not root-group-owned: $lock_dir"
  exec 9<>"$LOCK_PATH" || die "could not open database operation lock: $LOCK_PATH"
  "$FLOCK_BIN" -n 9 || die "another ACM database operation is active"
  lock_held=true
}

release_lock() {
  if "$lock_held"; then
    "$FLOCK_BIN" -u 9 || true
    exec 9>&-
    lock_held=false
  fi
}

compose() {
  "$DOCKER_BIN" compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

server_is_running() {
  local ids
  ids="$(compose ps -q server)" || die "could not determine server status"
  [ -n "$ids" ]
}

stop_server() {
  if server_is_running; then
    if "$dry_run"; then
      note "dry-run: would stop server"
    else
      compose stop server
      stopped_by_us=true
    fi
  fi
}

restart_if_needed() {
  local prior_status="$1"
  if "$stopped_by_us"; then
    note "starting the server that this invocation stopped"
    if ! compose start server; then
      note "server start failed; inspect Compose status and logs before further changes"
      [ "$prior_status" -ne 0 ] && return "$prior_status"
      return 1
    fi
  fi
  return "$prior_status"
}

backup_exit() {
  local status=$?
  trap - EXIT
  restart_if_needed "$status" || status=$?
  release_lock
  return "$status"
}

restore_exit() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    if [ -n "$restore_quarantine" ]; then
      note "restore is incomplete; server remains stopped. Original files are in: $restore_quarantine"
      note "Recovery: quarantine any partial db.sqlite files separately, move the original set back from that directory, then start server. Do not overwrite or delete files."
    elif "$stopped_by_us"; then
      note "restore failed after stopping the server; server remains stopped. Inspect the data directory before starting it."
    fi
    release_lock
    return "$status"
  fi
  restart_if_needed 0 || status=$?
  release_lock
  return "$status"
}

assert_db_set() {
  local dir="$1" contract="${2:-data}" name have_wal=false have_shm=false
  assert_no_conflicting_sidecars "$dir"
  [ -f "$dir/db.sqlite" ] && [ ! -L "$dir/db.sqlite" ] && [ -s "$dir/db.sqlite" ] || die "missing or invalid db.sqlite in $dir"
  for name in "${DB_NAMES[@]}"; do
    [ ! -e "$dir/$name" ] || [ ! -L "$dir/$name" ] || die "symlink database file rejected: $dir/$name"
  done
  [ -e "$dir/db.sqlite-wal" ] && have_wal=true
  [ -e "$dir/db.sqlite-shm" ] && have_shm=true
  if [ "$have_wal" != "$have_shm" ]; then
    die "WAL and SHM must be present together in $dir"
  fi
  for name in "${DB_NAMES[@]}"; do
    [ ! -e "$dir/$name" ] || {
      case "$contract" in
        data) assert_db_file "$dir/$name" ;;
        backup) assert_safe_file "$dir/$name" 400 ;;
        transient) assert_safe_file "$dir/$name" ;;
        *) die "invalid database set contract" ;;
      esac
    }
  done
}

# SQLite may leave rollback, master-journal, or implementation-specific
# sidecars behind. They are never valid members of an ACM backup payload.
assert_no_conflicting_sidecars() {
  local dir="$1" entry name
  for entry in "$dir"/db.sqlite-*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      db.sqlite-wal|db.sqlite-shm) continue;;
    esac
    [ ! -L "$entry" ] || die "symlink database sidecar rejected: $entry"
    [ -f "$entry" ] || die "nonregular database sidecar rejected: $entry"
    die "conflicting SQLite sidecar present: $entry"
  done
}

quarantine_current_db_set() {
  local source="$1" destination="$2" name entry
  # Reject unsafe sidecars before moving any file, so a failed restore leaves
  # the current database set untouched.
  assert_no_unsafe_conflicting_sidecars "$source"
  for name in "${DB_NAMES[@]}"; do
    [ ! -e "$source/$name" ] || mv "$source/$name" "$destination/$name"
  done
  for entry in "$source"/db.sqlite-*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      db.sqlite-wal|db.sqlite-shm) continue;;
    esac
    mv "$entry" "$destination/$name"
  done
}

assert_no_unsafe_conflicting_sidecars() {
  local dir="$1" entry name
  for entry in "$dir"/db.sqlite-*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      db.sqlite-wal|db.sqlite-shm) continue;;
    esac
    [ ! -L "$entry" ] || die "symlink database sidecar rejected: $entry"
    [ -f "$entry" ] || die "nonregular database sidecar rejected: $entry"
  done
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    die "SHA-256 tool unavailable; install sha256sum or shasum"
  fi
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d ' ' -f 1
  else
    die "SHA-256 tool unavailable; install sha256sum or shasum"
  fi
}

source_revision() {
  local revision
  revision="$(git -C "$REPO_DIR" rev-parse --verify HEAD)" || die "could not determine source revision"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "source revision is not a full SHA-1"
  printf '%s\n' "$revision"
}

assert_clean_checkout() {
  [ -z "$(git -C "$REPO_DIR" status --porcelain --untracked-files=all)" ] || die "backup requires a clean Git checkout"
}

migration_identity() {
  [ -d "$REPO_DIR/migrations" ] || die "migrations directory is missing"
  validate_migrations
  (
    cd "$REPO_DIR"
    while IFS= read -r migration; do
      [[ "$migration" != *$'\n'* ]] || die "migration filename contains a newline"
      assert_safe_file "$REPO_DIR/$migration"
      printf '%s\0' "$migration"
      cat -- "$migration"
      printf '\0'
    done < <(find -P migrations -type f -print | LC_ALL=C sort)
  ) | hash_stdin
}

validate_metadata() {
  local dir="$1" line key value format='' created='' revision='' migration='' seen_format=false seen_created=false seen_revision=false seen_migration=false
  [ -f "$dir/metadata.txt" ] && [ ! -L "$dir/metadata.txt" ] || die "missing metadata: $dir"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=};;
      *) die "invalid metadata format";;
    esac
    case "$key" in
      format) "$seen_format" && die "duplicate metadata field: format"; format="$value"; seen_format=true;;
      created_utc) "$seen_created" && die "duplicate metadata field: created_utc"; created="$value"; seen_created=true;;
      source_revision) "$seen_revision" && die "duplicate metadata field: source_revision"; revision="$value"; seen_revision=true;;
      migration_identity) "$seen_migration" && die "duplicate metadata field: migration_identity"; migration="$value"; seen_migration=true;;
      *) die "invalid metadata field: $key";;
    esac
  done < "$dir/metadata.txt"
  [ "$format" = acm-sqlite-backup-v2 ] || die "unsupported metadata format"
  [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "invalid metadata creation time"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "invalid metadata source revision"
  [[ "$migration" =~ ^[0-9a-f]{64}$ ]] || die "invalid metadata migration identity"
  VERIFIED_SOURCE_REVISION="$revision"
  VERIFIED_MIGRATION_IDENTITY="$migration"
}

verify_backup() {
  local dir="$1" allow_incomplete="${2:-false}" line hash name actual metadata_hash entry manifest_format='' manifest_revision='' manifest_migration='' manifest_metadata_hash='' seen_format=false seen_revision=false seen_migration=false seen_metadata=false seen_db=false seen_wal=false seen_shm=false
  dir="$(resolve_existing_dir "$dir")"
  if [ "$allow_incomplete" = true ]; then
    assert_private_root_dir "$dir" "incomplete backup directory"
    [ -f "$dir/INCOMPLETE" ] && [ ! -L "$dir/INCOMPLETE" ] || die "missing incomplete marker: $dir"
    [ ! -e "$dir/COMPLETE" ] || die "backup has conflicting completion markers: $dir"
  else
    assert_backup_payload_dir "$dir"
    [ ! -e "$dir/INCOMPLETE" ] || die "backup is incomplete: $dir"
    [ -f "$dir/COMPLETE" ] && [ ! -L "$dir/COMPLETE" ] || die "backup is missing COMPLETE marker: $dir"
  fi
  [ -f "$dir/manifest.sha256" ] && [ ! -L "$dir/manifest.sha256" ] || die "missing manifest: $dir"
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      db.sqlite|db.sqlite-wal|db.sqlite-shm|metadata.txt|manifest.sha256|COMPLETE) ;;
      INCOMPLETE) [ "$allow_incomplete" = true ] || die "backup is incomplete: $dir";;
      *) die "unknown backup file: $name";;
    esac
    [ -f "$entry" ] && [ ! -L "$entry" ] || die "backup entry is not a regular file: $name"
    if [ "$allow_incomplete" != true ]; then
      assert_safe_file "$entry" 400
    else
      assert_safe_file "$entry"
    fi
  done
  if [ "$allow_incomplete" = true ]; then assert_db_set "$dir" transient; else assert_db_set "$dir" backup; fi
  validate_metadata "$dir"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      format=*) "$seen_format" && die "duplicate manifest field: format"; manifest_format=${line#format=}; seen_format=true;;
      source_revision=*) "$seen_revision" && die "duplicate manifest field: source_revision"; manifest_revision=${line#source_revision=}; seen_revision=true;;
      migration_identity=*) "$seen_migration" && die "duplicate manifest field: migration_identity"; manifest_migration=${line#migration_identity=}; seen_migration=true;;
      metadata_sha256=*) "$seen_metadata" && die "duplicate manifest field: metadata_sha256"; manifest_metadata_hash=${line#metadata_sha256=}; seen_metadata=true;;
      [0-9a-f][0-9a-f]*)
        hash=${line%%  *}; name=${line#*  }
        [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "invalid manifest checksum"
        case "$name" in
          db.sqlite) "$seen_db" && die "duplicate manifest entry: $name"; seen_db=true;;
          db.sqlite-wal) "$seen_wal" && die "duplicate manifest entry: $name"; seen_wal=true;;
          db.sqlite-shm) "$seen_shm" && die "duplicate manifest entry: $name"; seen_shm=true;;
          *) die "invalid manifest entry: $name";;
        esac
        [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ] || die "manifest file missing: $name"
        actual="$(hash_file "$dir/$name")"
        [ "$hash" = "$actual" ] || die "checksum mismatch: $name"
        ;;
      *) die "invalid manifest format";;
    esac
  done < "$dir/manifest.sha256"
  [ "$manifest_format" = acm-sqlite-manifest-v2 ] || die "unsupported manifest format"
  [ "$manifest_revision" = "$VERIFIED_SOURCE_REVISION" ] || die "manifest source revision does not match metadata"
  [ "$manifest_migration" = "$VERIFIED_MIGRATION_IDENTITY" ] || die "manifest migration identity does not match metadata"
  metadata_hash="$(hash_file "$dir/metadata.txt")"
  [ "$manifest_metadata_hash" = "$metadata_hash" ] || die "metadata checksum mismatch"
  "$seen_db" || die "db.sqlite is not listed in manifest"
  if [ -e "$dir/db.sqlite-wal" ]; then "$seen_wal" && "$seen_shm" || die "WAL files are not listed in manifest"; else ! "$seen_wal" && ! "$seen_shm" || die "unexpected WAL manifest entries"; fi
  note "backup verified: $dir"
}

new_directory() {
  local root="$1" prefix="$2" candidate i
  for i in $(seq 1 100); do
    candidate="$root/${prefix}$(date -u +%Y%m%dT%H%M%SZ)-$$-$i"
    if mkdir -m 0700 -- "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die "could not create a unique directory under $root"
}

copy_set() {
  local source="$1" destination="$2" name
  for name in "${DB_NAMES[@]}"; do
    if [ -e "$source/$name" ]; then
      cp -p "$source/$name" "$destination/$name"
    fi
  done
}

write_metadata() {
  local dir="$1" name revision migration
  revision="$(source_revision)"
  migration="$(migration_identity)"
  {
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'format=acm-sqlite-backup-v2\n'
    printf 'source_revision=%s\n' "$revision"
    printf 'migration_identity=%s\n' "$migration"
  } > "$dir/metadata.txt"
  {
    printf 'format=acm-sqlite-manifest-v2\n'
    printf 'source_revision=%s\n' "$revision"
    printf 'migration_identity=%s\n' "$migration"
    printf 'metadata_sha256=%s\n' "$(hash_file "$dir/metadata.txt")"
  } > "$dir/manifest.sha256"
  for name in "${DB_NAMES[@]}"; do
    [ ! -e "$dir/$name" ] || printf '%s  %s\n' "$(hash_file "$dir/$name")" "$name" >> "$dir/manifest.sha256"
  done
}

backup() {
  local root="$1" data backup_dir
  if "$dry_run"; then
    root="$(resolve_existing_dir "$root")"
    data="$(resolve_existing_dir "$(current_data_dir_input)")"
    assert_separate "$data" "$root"
    assert_private_root_dir "$root" "backup root"
    assert_data_dir "$data"; assert_db_set "$data" data
    note "dry-run: would create a complete backup below $root"
    return 0
  fi
  require_root; acquire_lock
  trap backup_exit EXIT
  validate_repository
  root="$(resolve_existing_dir "$root")"
  data="$(resolve_existing_dir "$(current_data_dir_input)")"
  assert_separate "$data" "$root"
  assert_private_root_dir "$root" "backup root"
  assert_data_dir "$data"; assert_db_set "$data" data
  assert_clean_checkout
  stop_server
  # The set is checked again after stopping so WAL/SHM are from one session.
  assert_data_dir "$data"; assert_db_set "$data" data
  backup_dir="$(new_directory "$root" 'acm-backup-')"
  assert_private_root_dir "$backup_dir" "incomplete backup directory"
  : > "$backup_dir/INCOMPLETE"
  assert_data_dir "$data"; assert_db_set "$data" data
  copy_set "$data" "$backup_dir"
  if [ "$TEST_MODE" = 0 ]; then
    for name in "${DB_NAMES[@]}"; do
      [ ! -e "$backup_dir/$name" ] || chown root:root "$backup_dir/$name"
    done
  fi
  assert_db_set "$backup_dir" transient
  assert_clean_checkout
  source_revision >/dev/null
  migration_identity >/dev/null
  write_metadata "$backup_dir"
  verify_backup "$backup_dir" true
  chmod 0400 "$backup_dir"/*
  mv "$backup_dir/INCOMPLETE" "$backup_dir/COMPLETE"
  chmod 0500 "$backup_dir"
  verify_backup "$backup_dir"
  trap - EXIT
  if ! restart_if_needed 0; then
    release_lock
    return 1
  fi
  release_lock
  printf 'BACKUP_DIR=%s\n' "$backup_dir"
}

ensure_quarantine_root() {
  local requested="$1" data="$2" dry_run="${3:-false}" parent root data_filesystem root_filesystem
  if [ -n "$requested" ]; then
    root="$(resolve_existing_dir "$requested")"
  else
    parent="$(dirname -- "$data")"
    root="$parent/.acm-quarantine"
    if [ ! -e "$root" ] && [ "$dry_run" != true ]; then
      mkdir -m 0700 "$root" || die "could not create quarantine root: $root"
    fi
    if [ -e "$root" ]; then
      root="$(resolve_existing_dir "$root")"
    elif [ "$dry_run" = true ]; then
      parent="$(resolve_existing_dir "$parent")"
      root="$parent/.acm-quarantine"
    else
      die "could not create quarantine root: $root"
    fi
  fi
  assert_separate "$data" "$root"
  if [ -e "$root" ]; then
    assert_private_root_dir "$root" "quarantine root"
  else
    [ "$dry_run" = true ] || die "quarantine root does not exist: $root"
    assert_trusted_ancestors "$root"
  fi
  data_filesystem="$(filesystem_id "$data")"
  if [ -e "$root" ]; then root_filesystem="$(filesystem_id "$root")"; else root_filesystem="$(filesystem_id "$parent")"; fi
  [ "$data_filesystem" = "$root_filesystem" ] || die "quarantine root must be on the ACM_DATA_DIR filesystem"
  if [ -e "$root" ]; then assert_private_root_dir "$root" "quarantine root"; fi
  printf '%s\n' "$root"
}

restore() {
  local backup="$1" requested_quarantine="$2" data quarantine_root name
  if "$dry_run"; then
    backup="$(resolve_existing_dir "$backup")"
    data="$(resolve_existing_dir "$(current_data_dir_input)")"
    assert_data_dir "$data"; assert_separate "$data" "$backup"
    verify_backup "$backup"
    quarantine_root="$(ensure_quarantine_root "$requested_quarantine" "$data" true)"
    assert_separate "$backup" "$quarantine_root"
    note "dry-run: would quarantine current data under $quarantine_root and restore $backup"
    return 0
  fi
  require_root; acquire_lock
  trap restore_exit EXIT
  validate_repository
  backup="$(resolve_existing_dir "$backup")"
  data="$(resolve_existing_dir "$(current_data_dir_input)")"
  assert_data_dir "$data"; assert_separate "$data" "$backup"
  verify_backup "$backup" # Validation occurs under the mutation lock.
  quarantine_root="$(ensure_quarantine_root "$requested_quarantine" "$data")"
  assert_separate "$backup" "$quarantine_root"
  stop_server
  assert_data_dir "$data"
  verify_backup "$backup"
  assert_no_unsafe_conflicting_sidecars "$data"
  restore_quarantine="$(new_directory "$quarantine_root" 'acm-quarantine-')"
  assert_private_root_dir "$restore_quarantine" "quarantine directory"
  quarantine_current_db_set "$data" "$restore_quarantine"
  assert_no_conflicting_sidecars "$data"
  verify_backup "$backup"
  copy_set "$backup" "$data"
  for name in "${DB_NAMES[@]}"; do
    [ ! -e "$data/$name" ] || chmod 0600 "$data/$name"
    [ "$TEST_MODE" = 1 ] || [ ! -e "$data/$name" ] || chown 10001:10001 "$data/$name"
  done
  assert_db_set "$data" data
  note "restore complete; previous database files quarantined in: $restore_quarantine"
}

metadata() {
  local backup="$1"
  verify_backup "$backup"
  backup="$(resolve_existing_dir "$backup")"
  printf 'BACKUP_DIR=%s\n' "$backup"
  printf 'SOURCE_REVISION=%s\n' "$VERIFIED_SOURCE_REVISION"
  printf 'MIGRATION_IDENTITY=%s\n' "$VERIFIED_MIGRATION_IDENTITY"
}

command=${1:-}
[ -n "$command" ] || { usage >&2; exit 2; }
shift
backup_root="" backup_dir="" quarantine_root="" confirmed=false
while [ $# -gt 0 ]; do
  case "$1" in
    --backup-root) backup_root=${2:-}; shift 2;;
    --backup-dir) backup_dir=${2:-}; shift 2;;
    --quarantine-root) quarantine_root=${2:-}; shift 2;;
    --yes-restore) confirmed=true; shift;;
    --dry-run) dry_run=true; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done

case "$command" in
  backup) [ -n "$backup_root" ] || die "backup requires --backup-root"; backup "$backup_root";;
  verify) [ -n "$backup_dir" ] || die "verify requires --backup-dir"; verify_backup "$backup_dir";;
  metadata) [ -n "$backup_dir" ] || die "metadata requires --backup-dir"; metadata "$backup_dir";;
  restore)
    [ -n "$backup_dir" ] || die "restore requires --backup-dir"
    "$confirmed" || die "restore requires --yes-restore"
    restore "$backup_dir" "$quarantine_root"
    ;;
  *) usage >&2; exit 2;;
esac
