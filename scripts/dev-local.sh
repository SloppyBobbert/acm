#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/.local/logs"

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
: "${API_HOSTNAME:=127.0.0.1}"
: "${PORT:=8081}"
: "${RAMIEL_HOSTNAME:=127.0.0.1}"
: "${RAMIEL_PORT:=8082}"
: "${RAMIEL_URL:=http://$RAMIEL_HOSTNAME:$RAMIEL_PORT}"
: "${FRONTEND_PORT:=3000}"
: "${NEXT_PUBLIC_API_URL:=http://$API_HOSTNAME:$PORT}"
: "${NEXT_PUBLIC_WS_URL:=ws://$API_HOSTNAME:$PORT/ws}"

if [[ "$DATABASE_URL" == sqlite://./* ]]; then
    touch "$ROOT_DIR/${DATABASE_URL#sqlite://./}"
elif [[ "$DATABASE_URL" == sqlite:///* ]]; then
    touch "${DATABASE_URL#sqlite://}"
fi

cleanup() {
    for pid in ${server_pid:-} ${ramiel_pid:-}; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT INT TERM

echo "Building server and Ramiel..."
(cd "$ROOT_DIR" && cargo build -p server -p ramiel)

if [[ ! -d "$ROOT_DIR/lilith/node_modules" ]]; then
    echo "Installing frontend dependencies..."
    (cd "$ROOT_DIR/lilith" && corepack yarn install --frozen-lockfile)
fi

echo "Starting Ramiel at http://$RAMIEL_HOSTNAME:$RAMIEL_PORT"
(cd "$ROOT_DIR" && "$ROOT_DIR/target/debug/ramiel" \
    --hostname "$RAMIEL_HOSTNAME" \
    --port "$RAMIEL_PORT") \
    > "$LOG_DIR/ramiel.log" 2>&1 &
ramiel_pid=$!

echo "Starting API at http://$API_HOSTNAME:$PORT"
(cd "$ROOT_DIR" && JWT_SECRET="$JWT_SECRET" DISCORD_SECRET="$DISCORD_SECRET" "$ROOT_DIR/target/debug/server" \
    --hostname "$API_HOSTNAME" \
    --port "$PORT" \
    --database-url "$DATABASE_URL" \
    --ramiel-url "$RAMIEL_URL" \
    --frontend-origin "$FRONTEND_ORIGIN" \
    --cookie-secure "$COOKIE_SECURE") \
    > "$LOG_DIR/server.log" 2>&1 &
server_pid=$!

echo "Starting frontend at http://127.0.0.1:$FRONTEND_PORT"
echo "Logs: $LOG_DIR"

(cd "$ROOT_DIR/lilith" && \
    NEXT_PUBLIC_API_URL="$NEXT_PUBLIC_API_URL" \
    NEXT_PUBLIC_WS_URL="$NEXT_PUBLIC_WS_URL" \
    corepack yarn dev -p "$FRONTEND_PORT")
