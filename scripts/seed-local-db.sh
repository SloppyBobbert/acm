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

CONTENT_ROW_COUNT="$(sqlite3 "$DB_PATH" <<'SQL'
SELECT
    (SELECT COUNT(*) FROM users) +
    (SELECT COUNT(*) FROM meetings) +
    (SELECT COUNT(*) FROM activities) +
    (SELECT COUNT(*) FROM competitions) +
    (SELECT COUNT(*) FROM problems) +
    (SELECT COUNT(*) FROM tests) +
    (SELECT COUNT(*) FROM submissions) +
    (SELECT COUNT(*) FROM teams) +
    (SELECT COUNT(*) FROM team_members);
SQL
)"

SEED_ROW_COUNT="$(sqlite3 "$DB_PATH" <<'SQL'
SELECT
    (SELECT COUNT(*) FROM users WHERE id = 1 AND username = 'local-officer' AND discord_id = 'local-officer') +
    (SELECT COUNT(*) FROM users WHERE id = 2 AND username = 'local-member' AND discord_id = 'local-member') +
    (SELECT COUNT(*) FROM meetings WHERE id = 1 AND title = 'Local ACM Practice Night') +
    (SELECT COUNT(*) FROM activities WHERE id = 1 AND meeting_id = 1 AND title = 'Warm-up problems') +
    (SELECT COUNT(*) FROM competitions WHERE id = 1 AND name = 'Local Practice Contest') +
    (SELECT COUNT(*) FROM problems WHERE id = 1 AND title = 'Add One') +
    (SELECT COUNT(*) FROM problems WHERE id = 2 AND title = 'Double It') +
    (SELECT COUNT(*) FROM tests WHERE id = 1 AND problem_id = 1) +
    (SELECT COUNT(*) FROM tests WHERE id = 2 AND problem_id = 1) +
    (SELECT COUNT(*) FROM tests WHERE id = 3 AND problem_id = 2) +
    (SELECT COUNT(*) FROM submissions WHERE id = 1 AND problem_id = 1 AND user_id = 1);
SQL
)"

if [[ "$CONTENT_ROW_COUNT" -gt 0 && "$SEED_ROW_COUNT" -ne 11 ]]; then
    echo "Refusing to seed a non-empty database that does not match the local seed data." >&2
    echo "Use an empty local SQLite database, or back up/reset $DB_PATH before seeding." >&2
    exit 1
fi

sqlite3 "$DB_PATH" < "$ROOT_DIR/scripts/seed-local-db.sql"

echo "Seeded local development data into $DB_PATH"
