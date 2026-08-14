# Production deployment

The frontend stays on Vercel. Set `NEXT_PUBLIC_API_URL=https://api.example.com` and `NEXT_PUBLIC_WS_URL=wss://api.example.com/ws`, replacing `api.example.com` with the API domain served by this VM. This stack is Caddy -> server -> Ramiel; only Caddy exposes ports 80 and 443.

## VM setup

1. Assign the VM a DNS label or domain, then create an A/AAAA record for the API hostname.
2. Copy `deploy/.env.production.example` to `deploy/.env.production`. Set `API_DOMAIN`, `FRONTEND_ORIGIN` to the exact HTTPS frontend origin (for example, its Vercel or custom domain), generate a long random `JWT_SECRET`, and set the Discord client secret. Keep this file out of source control. Production Compose always enables secure cookies.
3. Create the SQLite data directory from `ACM_DATA_DIR` before starting. The server runs as UID `10001`, so the directory must be writable by that UID: `mkdir -p .local/production-data && chown 10001:10001 .local/production-data`.
4. Start and inspect the stack:

   ```sh
   docker compose --env-file deploy/.env.production -f compose.production.yml up -d --build
   docker compose --env-file deploy/.env.production -f compose.production.yml ps
   docker compose --env-file deploy/.env.production -f compose.production.yml logs -f caddy server ramiel
   ```

5. Update the Discord application's redirect URL to use the production frontend/API flow before enabling sign-in.

Caddy's health check requests the server's `/healthz` endpoint through the configured HTTPS domain while resolving it to the local Caddy process.

Caddy runs as UID/GID `10001`; its named `/data` and `/config` volumes must remain writable by that account.

When upgrading volumes created by the former root-running Caddy image, migrate their ownership while Caddy is stopped:

```sh
docker compose --env-file deploy/.env.production -f compose.production.yml stop caddy
docker compose --env-file deploy/.env.production -f compose.production.yml run --rm --no-deps --user 0:0 --cap-add CHOWN --entrypoint chown caddy -R 10001:10001 /data /config
docker compose --env-file deploy/.env.production -f compose.production.yml up -d caddy
```

## SQLite backup

Stop the server before copying the database and its WAL files, then restart it:

```sh
set -a
. deploy/.env.production
set +a
docker compose --env-file deploy/.env.production -f compose.production.yml stop server
cp "$ACM_DATA_DIR/db.sqlite" /safe/backup/db.sqlite
cp "$ACM_DATA_DIR/db.sqlite-wal" /safe/backup/db.sqlite-wal 2>/dev/null || true
cp "$ACM_DATA_DIR/db.sqlite-shm" /safe/backup/db.sqlite-shm 2>/dev/null || true
docker compose --env-file deploy/.env.production -f compose.production.yml start server
```
