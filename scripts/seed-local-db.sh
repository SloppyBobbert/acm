#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATABASE_URL="${DATABASE_URL:-sqlite://./db.sqlite}"

case "$DATABASE_URL" in
    sqlite://./*)
        DB_PATH="$ROOT_DIR/${DATABASE_URL#sqlite://./}"
        ;;
    sqlite:///*)
        DB_PATH="${DATABASE_URL#sqlite://}"
        ;;
    *)
        echo "Refusing to seed non-SQLite DATABASE_URL: $DATABASE_URL" >&2
        exit 1
        ;;
esac

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 is required to seed the local database." >&2
    exit 1
fi

if [[ ! -f "$DB_PATH" ]]; then
    echo "Database file does not exist: $DB_PATH" >&2
    echo "Run ./scripts/dev-local.sh once so migrations create the schema, then seed again." >&2
    exit 1
fi

if ! sqlite3 "$DB_PATH" "SELECT 1 FROM _sqlx_migrations LIMIT 1;" >/dev/null 2>&1; then
    echo "Database schema is missing migrations: $DB_PATH" >&2
    echo "Run ./scripts/dev-local.sh once so migrations create the schema, then seed again." >&2
    exit 1
fi

sqlite3 "$DB_PATH" < "$ROOT_DIR/scripts/seed-local-db.sql"

echo "Seeded local development data into $DB_PATH"
