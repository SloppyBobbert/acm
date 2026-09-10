#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/.local/logs"

# Next.js 12 crashes on Node 20+. Prefer Homebrew node@18 when present.
NODE18_BIN="$(brew --prefix 2>/dev/null)/opt/node@18/bin"
if [[ -x "${NODE18_BIN}/node" ]]; then
    export PATH="${NODE18_BIN}:$PATH"
fi

mkdir -p "$LOG_DIR"

if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ROOT_DIR/.env"
    set +a
fi

: "${DATABASE_URL:=sqlite://./db.sqlite}"
: "${JWT_SECRET:=dev-only-change-me}"
: "${DISCORD_SECRET:=dev-only-change-me}"
: "${FRONTEND_ORIGIN:=http://127.0.0.1:3000}"
: "${COOKIE_SECURE:=false}"
: "${DISCORD_CLIENT_ID:=local-discord-client-id}"
: "${DISCORD_REDIRECT_URI:=$FRONTEND_ORIGIN/auth/discord}"
: "${API_HOSTNAME:=127.0.0.1}"
: "${PORT:=8081}"
: "${RAMIEL_HOSTNAME:=127.0.0.1}"
: "${RAMIEL_PORT:=8082}"
: "${RAMIEL_URL:=http://$RAMIEL_HOSTNAME:$RAMIEL_PORT}"
: "${FRONTEND_PORT:=3000}"
: "${NEXT_PUBLIC_API_URL:=http://$API_HOSTNAME:$PORT}"
: "${NEXT_PUBLIC_WS_URL:=ws://$API_HOSTNAME:$PORT/ws}"

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

echo "Building server and Ramiel..."
(cd "$ROOT_DIR" && cargo build --locked -p server -p ramiel)

if [[ ! -d "$ROOT_DIR/lilith/node_modules" ]]; then
    echo "Installing frontend dependencies..."
    (cd "$ROOT_DIR/lilith" && corepack yarn@1.22.22 install --frozen-lockfile)
fi

start_ramiel() {
    local local_wasi="${WASI_SDK:-$ROOT_DIR/.local/wasi-sdk}"
    if [[ -x /opt/wasi-sdk/bin/clang++ ]]; then
        echo "Starting Ramiel at http://$RAMIEL_HOSTNAME:$RAMIEL_PORT"
        (cd "$ROOT_DIR" && "$ROOT_DIR/target/debug/ramiel" \
            --hostname "$RAMIEL_HOSTNAME" \
            --port "$RAMIEL_PORT") \
            > "$LOG_DIR/ramiel.log" 2>&1 &
        ramiel_pid=$!
    elif [[ -x "$local_wasi/bin/clang++" ]]; then
        echo "Starting Ramiel with WASI_SDK=$local_wasi at http://$RAMIEL_HOSTNAME:$RAMIEL_PORT"
        (cd "$ROOT_DIR" && WASI_SDK="$local_wasi" "$ROOT_DIR/target/debug/ramiel" \
            --hostname "$RAMIEL_HOSTNAME" \
            --port "$RAMIEL_PORT") \
            > "$LOG_DIR/ramiel.log" 2>&1 &
        ramiel_pid=$!
    elif command -v docker >/dev/null 2>&1; then
        echo "Starting Ramiel from Dockerfile.ramiel at http://$RAMIEL_HOSTNAME:$RAMIEL_PORT"
        docker build --platform linux/amd64 --provenance=false -f Dockerfile.ramiel \
            -t acm-ramiel:local "$ROOT_DIR"
        ramiel_container="acm-ramiel-local"
        docker rm -f "$ramiel_container" >/dev/null 2>&1 || true
        docker run --rm --name "$ramiel_container" --platform linux/amd64 \
            -p "$RAMIEL_HOSTNAME:$RAMIEL_PORT:8082" acm-ramiel:local \
            > "$LOG_DIR/ramiel.log" 2>&1 &
        ramiel_pid=$!
    else
        echo "error: Ramiel needs /opt/wasi-sdk, WASI_SDK, or Docker (Dockerfile.ramiel)." >&2
        exit 1
    fi
}

start_ramiel

echo "Starting API at http://$API_HOSTNAME:$PORT"
(cd "$ROOT_DIR" && \
    JWT_SECRET="$JWT_SECRET" \
    DISCORD_SECRET="$DISCORD_SECRET" \
    "$ROOT_DIR/target/debug/server" \
    --hostname "$API_HOSTNAME" \
    --port "$PORT" \
    --database-url "$DATABASE_URL" \
    --ramiel-url "$RAMIEL_URL" \
    --frontend-origin "$FRONTEND_ORIGIN" \
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
