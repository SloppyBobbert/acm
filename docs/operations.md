# Operations

Production commands require a completed `deploy/.env.production` copied from `deploy/.env.production.example` on the deployment host.

## Health and logs

```sh
set -euo pipefail
set -a
. deploy/.env.production
set +a
docker compose --env-file deploy/.env.production -f compose.production.yml ps
curl --fail --connect-timeout 5 --max-time 10 --resolve "${API_DOMAIN}:443:127.0.0.1" "https://${API_DOMAIN}/healthz"
docker compose --env-file deploy/.env.production -f compose.production.yml logs -f caddy server ramiel
```

The server and Ramiel each expose `/healthz` inside the stack. Caddy's health check reaches the API health endpoint through the configured HTTPS API domain. A successful API check means the server responded; it does not exercise the runner.

All three Compose services use `restart: unless-stopped`. A server restart loses in-memory queued jobs, job status, and WebSocket broadcasts. Persistent SQLite data remains in `ACM_DATA_DIR`.

## OAuth-start limits

The OAuth-start endpoint allows a global burst of 50 requests and refills five requests per second. Each client can burst five requests and refills one request every 30 seconds. Requests over either limit receive HTTP `429`; reduce retries and investigate abusive or misconfigured clients. These in-memory limits reset when the API process restarts. Caddy replaces `X-Forwarded-For` with the directly observed client address, and the server trusts only Caddy's fixed `172.30.0.2` address on the private edge network. If a CDN or load balancer is added, redesign and configure trusted-proxy handling instead of accepting arbitrary forwarded-address chains.

## First administrator

After deploying and starting the stack so migrations complete, the intended first operator must sign in with Discord before being promoted from `MEMBER`. In Discord, open **User Settings > Advanced** and enable **Developer Mode**. Then right-click the intended account/user and choose **Copy User ID**. Verify the copied ID belongs to that signed-in account before running:

```sh
docker compose --env-file deploy/.env.production -f compose.production.yml run --rm --no-deps server bootstrap-admin --database-url 'sqlite:///var/lib/acm/db.sqlite?mode=rw' --discord-id '<discord-id>'
```

The existing-file `mode=rw` URL does not create a database. The command creates no user, refuses missing or duplicate matches, and refuses once any administrator exists. Sign out and back in after promotion so the JWT reflects `ADMIN`.

## Backup and restore

Stop the server before copying SQLite. For every backup, create a new empty, uniquely named directory outside `ACM_DATA_DIR`; copy `db.sqlite` and only WAL/SHM sidecars from that stopped-server session into it.

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

If a restore copy fails, leave the server stopped. First quarantine any partial restored files in a new directory under `$quarantine_root`; then move the original set from `$quarantine_dir` back into `ACM_DATA_DIR` and start the server. Do not overwrite partial files with the original set. Test the procedure on a non-production copy before using it during an incident.

## Capacity and temporary storage

Monitor free space in `ACM_DATA_DIR` and Docker's storage area. SQLite lives in the mounted data directory. Ramiel uses a 512 MiB executable `/tmp` tmpfs in production; compilation or execution may fail when that space is exhausted. Compose limits Ramiel to 2 CPUs, 2 GiB memory, and 256 PIDs; the server is limited to 1 CPU and 512 MiB memory. The server's in-process queue limits active work with `PARALLEL_JOB_COUNT`.

## Incident triage

- **Caddy unhealthy:** confirm DNS resolves the API domain, ports 80/443 are reachable, and inspect Caddy logs. Its health check depends on the API HTTPS route.
- **Server unhealthy:** inspect server logs for missing required variables, SQLite access failures, or migration failures. Confirm the data directory is writable by UID `10001`.
- **Runner unhealthy or jobs fail:** inspect Ramiel logs and confirm the container is running on amd64. Check its `/tmp` capacity and configured resource limits.
- **Jobs disappear after a restart:** this is expected: queue and status data are process-local. Retry the request after services recover.
- **Frontend cannot authenticate or use the API:** verify the deployed frontend origin exactly matches `FRONTEND_ORIGIN`, and verify its API and WebSocket URLs use the public API domain.
- **Discord sign-in fails:** verify the API has `DISCORD_CLIENT_ID`, `DISCORD_REDIRECT_URI`, and `DISCORD_SECRET`; `DISCORD_REDIRECT_URI` must use `FRONTEND_ORIGIN`'s normalized scheme, host, and effective port, with the exact `/auth/discord` path and no credentials, query, or fragment. Register it in Discord and use HTTPS in production. The frontend needs only its public API and WebSocket URLs and starts the flow by navigating to the API start endpoint.
- **Login works locally but not in production:** use frontend and API hosts on one registrable custom domain, such as `app.example.com` and `api.example.com`. The session cookie is `SameSite=Lax`, and raw unrelated Vercel domains may be blocked as third parties.
- **OAuth start returns `429`:** reduce retries and check for abusive or misconfigured clients. If a CDN or load balancer was added, review the trusted-proxy design rather than accepting its forwarded-address chain by default.
