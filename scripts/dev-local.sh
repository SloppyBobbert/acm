#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/.local/logs"

# Prefer an existing Homebrew Node 18 installation when available.
if command -v brew >/dev/null 2>&1 && brew_prefix="$(brew --prefix 2>/dev/null)"; then
    NODE18_BIN="${brew_prefix}/opt/node@18/bin"
    if [[ -x "${NODE18_BIN}/node" ]]; then
        export PATH="${NODE18_BIN}:$PATH"
    fi
fi

mkdir -p "$LOG_DIR"

if [[ -f "${DEV_ENV_FILE:-$ROOT_DIR/.env}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${DEV_ENV_FILE:-$ROOT_DIR/.env}"
    set +a
elif [[ -n "${DEV_ENV_FILE:-}" && "$DEV_ENV_FILE" != /dev/null ]]; then
    echo "error: DEV_ENV_FILE must name an existing environment file (or /dev/null)." >&2
    exit 1
fi

: "${DATABASE_URL:=sqlite://./db.sqlite}"
: "${JWT_SECRET:=dev-only-change-me}"
: "${DISCORD_SECRET:=dev-only-change-me}"
: "${FRONTEND_PORT:=3000}"
: "${FRONTEND_ORIGIN:=http://127.0.0.1:$FRONTEND_PORT}"
: "${COOKIE_SECURE:=false}"
: "${DISCORD_CLIENT_ID:=local-discord-client-id}"
: "${DISCORD_REDIRECT_URI:=$FRONTEND_ORIGIN/auth/discord}"
: "${API_HOSTNAME:=127.0.0.1}"
: "${PORT:=8081}"
: "${RAMIEL_HOSTNAME:=127.0.0.1}"
: "${RAMIEL_PORT:=8082}"
: "${RAMIEL_URL:=http://$RAMIEL_HOSTNAME:$RAMIEL_PORT}"
: "${DEV_START_RAMIEL:=true}"
: "${NEXT_PUBLIC_API_URL:=http://$API_HOSTNAME:$PORT}"
: "${NEXT_PUBLIC_WS_URL:=ws://$API_HOSTNAME:$PORT/ws}"

if [[ "$FRONTEND_ORIGIN" != "http://127.0.0.1:$FRONTEND_PORT" ]]; then
    echo "error: FRONTEND_ORIGIN must match http://127.0.0.1:$FRONTEND_PORT for this local script." >&2
    exit 1
fi
if [[ "$DEV_START_RAMIEL" != true && "$DEV_START_RAMIEL" != false ]]; then
    echo "error: DEV_START_RAMIEL must be true or false." >&2
    exit 1
fi

if [[ "$DATABASE_URL" == sqlite://./* ]]; then
    db_path="$ROOT_DIR/${DATABASE_URL#sqlite://./}"
elif [[ "$DATABASE_URL" == sqlite:///* ]]; then
    db_path="${DATABASE_URL#sqlite://}"
else
    db_path=""
fi
if [[ -n "$db_path" && ! -s "$db_path" ]]; then
    mkdir -p "$(dirname "$db_path")"
    if command -v sqlite3 >/dev/null; then
        sqlite3 "$db_path" 'VACUUM;'
    else
        touch "$db_path"
    fi
fi

cleanup() {
    if [[ -n "${ramiel_container:-}" ]] && command -v docker >/dev/null 2>&1; then
        docker stop "$ramiel_container" >/dev/null 2>&1 || true
    fi
    for pid in ${server_pid:-} ${ramiel_pid:-}; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT INT TERM

export SQLX_OFFLINE="${SQLX_OFFLINE:-true}"
echo "Building API..."
(cd "$ROOT_DIR" && cargo build --locked -p server)
if [[ "$DEV_START_RAMIEL" == true ]]; then
    (cd "$ROOT_DIR" && cargo build --locked -p ramiel)
fi

if [[ ! -d "$ROOT_DIR/lilith/node_modules" ]]; then
    echo "Installing frontend dependencies..."
    (cd "$ROOT_DIR/lilith" && corepack yarn@1.22.22 install --frozen-lockfile)
fi

start_ramiel() {
    if [[ -x /opt/wasi-sdk/bin/clang++ ]]; then
        echo "Starting Ramiel at http://$RAMIEL_HOSTNAME:$RAMIEL_PORT"
        (cd "$ROOT_DIR" && "$ROOT_DIR/target/debug/ramiel" \
            --hostname "$RAMIEL_HOSTNAME" \
            --port "$RAMIEL_PORT") \
            > "$LOG_DIR/ramiel.log" 2>&1 &
        ramiel_pid=$!
    elif command -v docker >/dev/null 2>&1; then
        echo "Starting Ramiel from Dockerfile.ramiel at http://$RAMIEL_HOSTNAME:$RAMIEL_PORT"
        docker build --platform linux/amd64 --provenance=false -f "$ROOT_DIR/Dockerfile.ramiel" \
            -t acm-ramiel:local "$ROOT_DIR"
        ramiel_container="$(docker run --detach --rm --platform linux/amd64 \
            -p "$RAMIEL_HOSTNAME:$RAMIEL_PORT:8082" acm-ramiel:local)"
        docker logs --follow "$ramiel_container" > "$LOG_DIR/ramiel.log" 2>&1 &
        ramiel_pid=$!
    else
        echo "error: Ramiel needs /opt/wasi-sdk or Docker (Dockerfile.ramiel)." >&2
        exit 1
    fi
}

if [[ "$DEV_START_RAMIEL" == true ]]; then
    start_ramiel
else
    echo "Ramiel startup skipped. Run/Submit need a supported runner at $RAMIEL_URL."
fi

echo "Starting API at http://$API_HOSTNAME:$PORT"
(cd "$ROOT_DIR" && \
    JWT_SECRET="$JWT_SECRET" \
    DISCORD_SECRET="$DISCORD_SECRET" \
    FRONTEND_ORIGIN="$FRONTEND_ORIGIN" \
    "$ROOT_DIR/target/debug/server" \
    --hostname "$API_HOSTNAME" \
    --port "$PORT" \
    --database-url "$DATABASE_URL" \
    --ramiel-url "$RAMIEL_URL" \
    --cookie-secure "$COOKIE_SECURE" \
    --discord-client-id "$DISCORD_CLIENT_ID" \
    --discord-redirect-uri "$DISCORD_REDIRECT_URI") \
    > "$LOG_DIR/server.log" 2>&1 &
server_pid=$!

echo "Starting frontend at http://127.0.0.1:$FRONTEND_PORT"
echo "Logs: $LOG_DIR"

(cd "$ROOT_DIR/lilith" && \
    NEXT_PUBLIC_API_URL="$NEXT_PUBLIC_API_URL" \
    NEXT_PUBLIC_WS_URL="$NEXT_PUBLIC_WS_URL" \
    corepack yarn@1.22.22 dev -H 127.0.0.1 -p "$FRONTEND_PORT")
