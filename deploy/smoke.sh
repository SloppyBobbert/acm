#!/usr/bin/env bash
# Bounded, read-only production smoke test for Caddy -> server -> Ramiel.
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"

ENV_FILE="$SCRIPT_DIR/.env.production"
COMPOSE_FILE="$REPO_DIR/compose.production.yml"
DOCKER_BIN=docker
CURL_BIN=curl
TIMEOUT_BIN=timeout
RETRIES=12
RETRY_DELAY=5
DEADLINE_SECONDS=90
CONNECT_TIMEOUT=5
MAX_TIME=10
COMMAND_TIMEOUT=10
LOCAL_RESOLVE=0
DRY_RUN=0
TEST_MODE=0
INTERNAL_DEADLINE=0

usage() {
  printf 'Usage: %s [--repository-dir ABSOLUTE_PATH] [--resolve] [--dry-run]\n' "${0##*/}"
}

while (($#)); do
  case "$1" in
    --repository-dir) [ $# -ge 2 ] && [[ "$2" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$2" != *//* && "$2" != */./* && "$2" != */../* && "$2" != */. && "$2" != */.. && "$2" != */ ]] || { printf '%s\n' 'smoke: --repository-dir requires a normalized absolute literal path' >&2; exit 2; }; REPO_DIR=$2; shift ;;
    --resolve) LOCAL_RESOLVE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --test-mode) TEST_MODE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if ((TEST_MODE)) && [[ "${SMOKE_TEST_MODE:-}" != 1 ]]; then
  printf '%s\n' 'smoke: --test-mode requires SMOKE_TEST_MODE=1' >&2
  exit 2
fi

if (( ! TEST_MODE )); then
  while IFS= read -r smoke_variable; do
    case "$smoke_variable" in
      SMOKE_*)
        printf '%s\n' 'smoke: SMOKE_* overrides require --test-mode and SMOKE_TEST_MODE=1' >&2
        exit 2
        ;;
    esac
  done < <(compgen -e)
fi

# The deadline child receives a one-use capability through an inherited pipe.
# Do not use a parent PID here: timeout implementations may fork, exec, or
# replace themselves before starting the child.
if [[ -n "${_SMOKE_DEADLINE_MARKER:-}" || -n "${_SMOKE_DEADLINE_FD:-}" ]]; then
  deadline_marker=
  deadline_fd=${_SMOKE_DEADLINE_FD:-}
  if [[ "$deadline_fd" == 0 ]]; then
    if ! IFS= read -r deadline_marker <&0; then
      exec 0<&-
      printf '%s\n' 'smoke: invalid private deadline marker' >&2
      exit 2
    fi
    exec 0<&-
    if [[ "$deadline_marker" == "${_SMOKE_DEADLINE_MARKER:-}" ]]; then
      INTERNAL_DEADLINE=1
    else
      printf '%s\n' 'smoke: invalid private deadline marker' >&2
      exit 2
    fi
  else
    printf '%s\n' 'smoke: invalid private deadline marker' >&2
    exit 2
  fi
fi

if ((TEST_MODE)); then
  ENV_FILE="${SMOKE_ENV_FILE:-$ENV_FILE}"
  COMPOSE_FILE="${SMOKE_COMPOSE_FILE:-$COMPOSE_FILE}"
  DOCKER_BIN="${SMOKE_DOCKER_BIN:-$DOCKER_BIN}"
  CURL_BIN="${SMOKE_CURL_BIN:-$CURL_BIN}"
  TIMEOUT_BIN="${SMOKE_TIMEOUT_BIN:-$TIMEOUT_BIN}"
  RETRIES="${SMOKE_RETRIES:-$RETRIES}"
  RETRY_DELAY="${SMOKE_RETRY_DELAY:-$RETRY_DELAY}"
  DEADLINE_SECONDS="${SMOKE_DEADLINE_SECONDS:-$DEADLINE_SECONDS}"
  CONNECT_TIMEOUT="${SMOKE_CONNECT_TIMEOUT:-$CONNECT_TIMEOUT}"
  MAX_TIME="${SMOKE_MAX_TIME:-$MAX_TIME}"
  COMMAND_TIMEOUT="${SMOKE_COMMAND_TIMEOUT:-$COMMAND_TIMEOUT}"
fi

if (( ! TEST_MODE )); then
  ENV_FILE="$REPO_DIR/deploy/.env.production"
  COMPOSE_FILE="$REPO_DIR/compose.production.yml"
fi

non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 <= 86400))
}

positive_integer() {
  non_negative_integer "$1" && ((10#$1 > 0))
}

if ! non_negative_integer "$RETRIES" || ! non_negative_integer "$RETRY_DELAY"; then
  printf 'smoke: retry settings must be bounded non-negative integers\n' >&2
  exit 2
fi
if ! positive_integer "$DEADLINE_SECONDS" || ! positive_integer "$CONNECT_TIMEOUT" ||
  ! positive_integer "$MAX_TIME" || ! positive_integer "$COMMAND_TIMEOUT"; then
  printf 'smoke: timeout settings must be bounded positive integers\n' >&2
  exit 2
fi

# The outer timeout is a hard wall-clock deadline; bounded() additionally caps
# each Docker command to the remaining budget.
if (( ! DRY_RUN )) && ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
  printf 'smoke: required timeout command is unavailable: %s\n' "$TIMEOUT_BIN" >&2
  exit 2
fi
if (( ! DRY_RUN && ! INTERNAL_DEADLINE )); then
  deadline_args=()
  ((TEST_MODE)) && deadline_args+=(--test-mode)
  (( ! TEST_MODE )) && deadline_args+=(--repository-dir "$REPO_DIR")
  ((LOCAL_RESOLVE)) && deadline_args+=(--resolve)
  marker="deadline:$$:${RANDOM}${RANDOM}${RANDOM}"
  printf '%s\n' "$marker" |
    env _SMOKE_DEADLINE_MARKER="$marker" _SMOKE_DEADLINE_FD=0 "$TIMEOUT_BIN" --foreground "${DEADLINE_SECONDS}s" "$SCRIPT_PATH" "${deadline_args[@]}"
  exit $?
fi

if [[ ! -r "$ENV_FILE" ]]; then
  printf 'smoke: environment file is not readable: %s\n' "$ENV_FILE" >&2
  exit 2
fi
if [[ ! -r "$COMPOSE_FILE" ]]; then
  printf 'smoke: compose file is not readable: %s\n' "$COMPOSE_FILE" >&2
  exit 2
fi

API_DOMAIN=
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    API_DOMAIN=*) API_DOMAIN=${line#API_DOMAIN=} ;;
  esac
done <"$ENV_FILE"
API_DOMAIN=${API_DOMAIN%$'\r'}
if ((${#API_DOMAIN} >= 2)); then
  first_character=${API_DOMAIN:0:1}
  last_character=${API_DOMAIN: -1}
  if [[ "$first_character" == '"' && "$last_character" == '"' ]] ||
    [[ "$first_character" == "'" && "$last_character" == "'" ]]; then
    API_DOMAIN=${API_DOMAIN:1:${#API_DOMAIN}-2}
  fi
fi
if [[ ! "$API_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf 'smoke: API_DOMAIN is missing or invalid in %s\n' "$ENV_FILE" >&2
  exit 2
fi

compose() {
  bounded "$DOCKER_BIN" compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

bounded() {
  local now remaining command_timeout
  now="$(date +%s)"
  remaining=$((DEADLINE_SECONDS - (now - start_time)))
  ((remaining > 0)) || return 124
  command_timeout=$COMMAND_TIMEOUT
  if ((command_timeout > remaining)); then
    command_timeout=$remaining
  fi
  "$TIMEOUT_BIN" --foreground "${command_timeout}s" "$@"
}

diagnostics() {
  local reason="$1"
  printf 'smoke: %s\n' "$reason" >&2
  printf '%s\n' '--- compose ps ---' >&2
  compose ps >&2 || true
  printf '%s\n' '--- compose logs (last 100 lines) ---' >&2
  compose logs --tail 100 caddy server ramiel >&2 || true
}

fail() {
  diagnostics "$1"
  exit 1
}

deadline_fail() {
  diagnostics "$1"
  exit 124
}

service_healthy() {
  local service="$1" container state health
  container="$(compose ps -q "$service")" || return 1
  [[ -n "$container" && "$container" != *$'\n'* ]] || return 1
  read -r state health < <(bounded "$DOCKER_BIN" inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container") || return 1
  [[ "$state" == running && "$health" == healthy ]]
}

all_services_healthy() {
  local service
  for service in caddy server ramiel; do
    if ! service_healthy "$service"; then
      printf 'smoke: service not healthy: %s\n' "$service" >&2
      return 1
    fi
  done
}

if ((DRY_RUN)); then
  printf '%s\n' 'smoke: dry run; no commands executed'
  printf '+ '
  printf '%q ' "$TIMEOUT_BIN" --foreground "${COMMAND_TIMEOUT}s" "$DOCKER_BIN" compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
  printf '\n+ '
  printf '%q ' "$CURL_BIN" --fail --silent --show-error --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "https://${API_DOMAIN}/healthz"
  printf '\n'
  exit 0
fi

start_time="$(date +%s)"
attempt=0
while :; do
  if all_services_healthy; then
    break
  fi
  attempt=$((attempt + 1))
  now="$(date +%s)"
  if ((now - start_time >= DEADLINE_SECONDS)); then
    deadline_fail "services did not become healthy within ${DEADLINE_SECONDS}s"
  fi
  if ((attempt >= RETRIES)); then
    fail "services did not become healthy within ${DEADLINE_SECONDS}s"
  fi
  remaining=$((DEADLINE_SECONDS - (now - start_time)))
  if ((RETRY_DELAY < remaining)); then
    sleep "$RETRY_DELAY"
  else
    sleep "$remaining"
  fi
done

now="$(date +%s)"
remaining=$((DEADLINE_SECONDS - (now - start_time)))
if ((remaining <= 0)); then
  deadline_fail "services became healthy but the ${DEADLINE_SECONDS}s smoke-test deadline expired"
fi
curl_max_time=$MAX_TIME
if ((curl_max_time > remaining)); then
  curl_max_time=$remaining
fi
curl_connect_timeout=$CONNECT_TIMEOUT
if ((curl_connect_timeout > curl_max_time)); then
  curl_connect_timeout=$curl_max_time
fi
curl_args=("$CURL_BIN" --fail --silent --show-error --connect-timeout "$curl_connect_timeout" --max-time "$curl_max_time")
if ((LOCAL_RESOLVE)); then
  curl_args+=(--resolve "${API_DOMAIN}:443:127.0.0.1")
fi
curl_args+=("https://${API_DOMAIN}/healthz")

if ! "${curl_args[@]}" >/dev/null; then
  now="$(date +%s)"
  if ((now - start_time >= DEADLINE_SECONDS)); then
    deadline_fail "public API health check exceeded the ${DEADLINE_SECONDS}s smoke-test deadline"
  fi
  if ((LOCAL_RESOLVE)); then
    fail 'public API health check failed with local --resolve routing'
  fi
  fail 'public API health check failed through DNS'
fi

printf 'smoke: caddy, server, and ramiel are healthy; public API health check passed\n'
