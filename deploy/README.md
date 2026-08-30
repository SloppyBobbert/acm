# Production deployment

The production API stack runs on the deployment host as Caddy -> server -> Ramiel. Caddy is the only public container; it exposes ports 80 and 443. The frontend remains on Vercel and calls Caddy's API domain. Build this stack from the checked-out repository with `compose.production.yml`; do not treat GHCR artifacts as the canonical deployment source.

## Prerequisites

- A Linux host with Docker Engine and Docker Compose
- An A/AAAA record for the API domain pointing to the host
- Ports 80 and 443 reachable from the internet for Caddy and TLS
- A checkout of this repository on the deployment host

## Configure the host

Copy the production example outside version control and supply each required value:

```sh
cp deploy/.env.production.example deploy/.env.production
```

Set `API_DOMAIN`, `FRONTEND_ORIGIN`, `JWT_SECRET`, `DISCORD_CLIENT_ID`, `DISCORD_REDIRECT_URI`, and `DISCORD_SECRET`. Generate a long, unique `JWT_SECRET`. `ACM_DATA_DIR` defaults to `./.local/production-data`; choose a persistent host path if needed. `PARALLEL_JOB_COUNT` defaults to `1` and must be at least `1` (`0` parses but is unsupported).

Set `DISCORD_REDIRECT_URI` with the normalized scheme, host, and effective port of `FRONTEND_ORIGIN`, the `/auth/discord` path, and no credentials, query, or fragment. Register that URI in the Discord application. Production uses HTTPS; HTTP is allowed only for insecure localhost development. Restrict the environment file after creating it:

```sh
chmod 600 deploy/.env.production
```

Anyone with Docker access can read container environment secrets, including this file's values.

The server runs as UID/GID `10001`, so root privilege is required to create the selected data directory with the right ownership before the first start:

```sh
sudo install -d -o 10001 -g 10001 .local/production-data
```

If `ACM_DATA_DIR` names another path, create and chown that path instead. Production Ramiel is amd64. Set `ACM_DOCKER_PLATFORM=linux/amd64` on Apple Silicon hosts.

## Deploy

Run these commands from the repository root on the deployment host:

```sh
docker compose --env-file deploy/.env.production -f compose.production.yml config --quiet
docker compose --env-file deploy/.env.production -f compose.production.yml build
docker compose --env-file deploy/.env.production -f compose.production.yml up -d
docker compose --env-file deploy/.env.production -f compose.production.yml ps
docker compose --env-file deploy/.env.production -f compose.production.yml logs -f caddy server ramiel
```

Caddy obtains and serves TLS for `API_DOMAIN` after DNS and public ports are correct. `config --quiet` validates the resolved configuration without printing interpolated values, including secrets.

## First administrator

After the stack starts and the server has completed its migrations, have the intended first operator sign in with Discord. This creates the operator's account as `MEMBER`. In Discord, open **User Settings > Advanced** and enable **Developer Mode**. Then right-click the intended account/user and choose **Copy User ID**. Verify the copied ID belongs to that signed-in account before running the bundled first-admin command from the repository root:

```sh
docker compose --env-file deploy/.env.production -f compose.production.yml run --rm --no-deps server bootstrap-admin --database-url 'sqlite:///var/lib/acm/db.sqlite?mode=rw' --discord-id '<discord-id>'
```

The `mode=rw` URL requires the mounted database to already exist; it does not create one. The command creates no user, promotes only the selected existing account, and is first-admin-only: it refuses missing or duplicate user matches and refuses to run once any administrator exists. Sign out and sign back in after a successful promotion so the new JWT reflects `ADMIN`.

## Frontend deployment

Configure the frontend build environment with public API and WebSocket URLs only:

```text
NEXT_PUBLIC_API_URL=https://api.example.com
NEXT_PUBLIC_WS_URL=wss://api.example.com/ws
```

Replace `api.example.com` with `API_DOMAIN`. Set `FRONTEND_ORIGIN` to the frontend origin for credentialed CORS. The frontend navigates to the API start endpoint; it does not need Discord OAuth values. Set `DISCORD_CLIENT_ID`, `DISCORD_REDIRECT_URI`, and `DISCORD_SECRET` only on the API host. `DISCORD_REDIRECT_URI` must use the normalized scheme, host, and effective port of `FRONTEND_ORIGIN`, with the `/auth/discord` path and no credentials, query, or fragment; register it in Discord. Rebuild and redeploy the frontend after changing its public API or WebSocket URL. Never put secrets in `NEXT_PUBLIC_*` variables.

Use a shared registrable custom domain for the frontend and API, such as `app.example.com` and `api.example.com`. The session cookie remains `SameSite=Lax`; a raw, unrelated Vercel domain can be blocked by third-party-cookie policies.

## Smoke tests

After containers report healthy, check the public route from the host:

```sh
set -euo pipefail
set -a
. deploy/.env.production
set +a
curl --fail --connect-timeout 5 --max-time 10 --resolve "${API_DOMAIN}:443:127.0.0.1" "https://${API_DOMAIN}/healthz"
docker compose --env-file deploy/.env.production -f compose.production.yml ps
```

Review logs if a service is not healthy. The public API health endpoint does not run a compilation job.

## Rollback

Keep the previous working repository revision and a current database backup. Before rolling back code, review migration compatibility. If the older code is incompatible with the migrated schema, coordinate restoration of the matching pre-deployment database backup. Then check out the previous revision on the host, run `docker compose ... build`, and `docker compose ... up -d`. Confirm health checks and logs after either action.

## Backup and restore

Stop the server before copying the database. For each backup, create a new empty, uniquely named directory outside `ACM_DATA_DIR`; capture `db.sqlite` and only same-session WAL/SHM sidecars while the server remains stopped:

```sh
set -euo pipefail
set -a
. deploy/.env.production
set +a
docker compose --env-file deploy/.env.production -f compose.production.yml stop server
backup_dir=""
backup_complete=0
backup_cleanup() {
  exit_status=$?
  trap - EXIT
  if [ "$exit_status" -ne 0 ]; then
    if [ -n "$backup_dir" ] && [ "$backup_complete" -eq 0 ]; then
      sudo touch "$backup_dir/INCOMPLETE" || true
    fi
    docker compose --env-file deploy/.env.production -f compose.production.yml start server || true
  fi
  exit "$exit_status"
}
trap backup_cleanup EXIT
backup_root=/var/backups/acm # operator-chosen path, outside ACM_DATA_DIR
quarantine_root=/var/lib/acm-quarantine # choose the ACM_DATA_DIR filesystem if practical
sudo install -d -m 700 -o root -g root "$backup_root" "$quarantine_root"
backup_dir="$(sudo mktemp -d "$backup_root/acm-XXXXXXXX")"
sudo cp "$ACM_DATA_DIR/db.sqlite" "$backup_dir/"
for sidecar in db.sqlite-wal db.sqlite-shm; do
  sudo test ! -e "$ACM_DATA_DIR/$sidecar" || sudo cp "$ACM_DATA_DIR/$sidecar" "$backup_dir/"
done
backup_complete=1
docker compose --env-file deploy/.env.production -f compose.production.yml start server
trap - EXIT
```

After a successful copy, restart the server as shown. If a later command fails, the EXIT handler marks an unfinished created directory with `INCOMPLETE` and attempts to restart the server while preserving the failure status. Backups containing `INCOMPLETE` are unusable.

To restore, set `backup_dir` to the selected immutable backup directory in the current shell; it does not persist from the backup session. Stop the server, create a new empty quarantine directory, and move the existing database set before copying that one matching backup set:

```sh
set -euo pipefail
set -a
. deploy/.env.production
set +a
backup_root=/var/backups/acm # operator-chosen path, outside ACM_DATA_DIR
quarantine_root=/var/lib/acm-quarantine # choose the ACM_DATA_DIR filesystem if practical
sudo install -d -m 700 -o root -g root "$backup_root" "$quarantine_root"
backup_dir="$backup_root/acm-REPLACE_ME"
sudo test ! -e "$backup_dir/INCOMPLETE"
sudo test -f "$backup_dir/db.sqlite"
docker compose --env-file deploy/.env.production -f compose.production.yml stop server
quarantine_dir="$(sudo mktemp -d "$quarantine_root/acm-XXXXXXXX")"
for name in db.sqlite db.sqlite-wal db.sqlite-shm; do
  sudo test ! -e "$ACM_DATA_DIR/$name" || sudo mv "$ACM_DATA_DIR/$name" "$quarantine_dir/"
done
sudo cp "$backup_dir/db.sqlite" "$ACM_DATA_DIR/"
for sidecar in db.sqlite-wal db.sqlite-shm; do
  sudo test ! -e "$backup_dir/$sidecar" || sudo cp "$backup_dir/$sidecar" "$ACM_DATA_DIR/"
done
for name in db.sqlite db.sqlite-wal db.sqlite-shm; do
  sudo test ! -e "$ACM_DATA_DIR/$name" || sudo chown 10001:10001 "$ACM_DATA_DIR/$name"
done
docker compose --env-file deploy/.env.production -f compose.production.yml start server
```

If a restore copy fails, leave the server stopped. First quarantine any partial restored files in a new directory under `$quarantine_root`; then move the original set from `$quarantine_dir` back into `ACM_DATA_DIR` and start the server. Do not overwrite partial files with the original set. Practice restores outside production first.

## Security checklist

- Keep `deploy/.env.production` private and out of Git.
- Restrict `deploy/.env.production` with `chmod 600`; Docker access can read container environment secrets.
- Use unique production values for `JWT_SECRET` and `DISCORD_SECRET`.
- Set `FRONTEND_ORIGIN` to one exact HTTPS origin.
- Expose only application ports 80 and 443; restrict administrative host access separately.
- Back up `ACM_DATA_DIR` and protect backups as application data.
- Keep Docker and the host patched.

## Existing Caddy volumes

Caddy runs as UID/GID `10001`. If named `/data` or `/config` volumes were created by the former root-running image, migrate their ownership while Caddy is stopped:

```sh
docker compose --env-file deploy/.env.production -f compose.production.yml stop caddy
docker compose --env-file deploy/.env.production -f compose.production.yml run --rm --no-deps --user 0:0 --cap-add CHOWN --entrypoint chown caddy -R 10001:10001 /data /config
docker compose --env-file deploy/.env.production -f compose.production.yml up -d caddy
```
