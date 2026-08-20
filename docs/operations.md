# Operations

Production commands require a completed `deploy/.env.production` copied from `deploy/.env.production.example` on the deployment host.

## Health and logs

```sh
set -euo pipefail
set -a
. deploy/.env.production
set +a
docker compose --env-file deploy/.env.production -f compose.production.yml ps
docker compose --env-file deploy/.env.production -f compose.production.yml logs -f caddy server ramiel
curl --fail --resolve "${API_DOMAIN}:443:127.0.0.1" "https://${API_DOMAIN}/healthz"
```

The server and Ramiel each expose `/healthz` inside the stack. Caddy's health check reaches the API health endpoint through the configured HTTPS API domain. A successful API check means the server responded; it does not exercise the runner.

All three Compose services use `restart: unless-stopped`. A server restart loses in-memory queued jobs, job status, and WebSocket broadcasts. Persistent SQLite data remains in `ACM_DATA_DIR`.

## Backup and restore

Stop the server before copying SQLite. For every backup, create a new empty, uniquely named directory outside `ACM_DATA_DIR`; copy `db.sqlite` and only WAL/SHM sidecars from that stopped-server session into it.

```sh
set -euo pipefail
set -a
. deploy/.env.production
set +a
docker compose --env-file deploy/.env.production -f compose.production.yml stop server
backup_root=/var/backups/acm # operator-chosen path, outside ACM_DATA_DIR
quarantine_root=/var/lib/acm-quarantine # choose the ACM_DATA_DIR filesystem if practical
sudo install -d -m 700 -o root -g root "$backup_root" "$quarantine_root"
backup_dir="$(sudo mktemp -d "$backup_root/acm-XXXXXXXX")"
sudo cp "$ACM_DATA_DIR/db.sqlite" "$backup_dir/"
for sidecar in db.sqlite-wal db.sqlite-shm; do
  sudo test ! -e "$ACM_DATA_DIR/$sidecar" || sudo cp "$ACM_DATA_DIR/$sidecar" "$backup_dir/"
done
docker compose --env-file deploy/.env.production -f compose.production.yml start server
```

After a successful copy, restart the server as shown. If a copy fails, do not use that backup; restart the server with `docker compose --env-file deploy/.env.production -f compose.production.yml start server`, then investigate.

To restore, set `backup_dir` to the selected immutable backup directory in the current shell; it does not persist from the backup session. Stop the server, create a new empty quarantine directory, and move the existing database set before copying that one matching backup set:

```sh
set -euo pipefail
set -a
. deploy/.env.production
set +a
docker compose --env-file deploy/.env.production -f compose.production.yml stop server
backup_root=/var/backups/acm # operator-chosen path, outside ACM_DATA_DIR
quarantine_root=/var/lib/acm-quarantine # choose the ACM_DATA_DIR filesystem if practical
sudo install -d -m 700 -o root -g root "$backup_root" "$quarantine_root"
backup_dir="$backup_root/acm-REPLACE_ME"
sudo test -f "$backup_dir/db.sqlite"
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
