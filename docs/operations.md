# Operations

Production commands require a completed `deploy/.env.production`, created as `root:root` mode `0600` with `sudoedit`, on a checkout that satisfies the production trust lane. `/opt/acm` and `/srv/acm` are recommended, not exclusive; another normalized absolute path is permitted only with root-owned, non-symlinked, non-group/world-writable ancestors and deployment inputs. Data's final directory is `10001:10001` mode `0750` with root-owned ancestors. Backup, quarantine, and state roots are `root:root` mode `0700`; state files are mode `0600`. The launch, lifecycle, and backup contracts are in [deployment](../deploy/README.md); use the scripts rather than manual database-copy procedures. Run every production command with `sudo`.

## Health and logs

```sh
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" status
sudo /usr/local/libexec/acm/smoke.sh --repository-dir "$(pwd -P)" --resolve
sudo docker compose --env-file deploy/.env.production -f compose.production.yml logs -f caddy server ramiel
```

The server and Ramiel each expose `/healthz` inside the stack. Caddy's health check reaches the API health endpoint through the configured HTTPS API domain. A successful API check means the server responded; it does not exercise the runner.

All three Compose services use `restart: unless-stopped`. A server restart loses in-memory queued jobs, job status, and WebSocket broadcasts. Persistent SQLite data remains in `ACM_DATA_DIR`.

## OAuth-start limits

The OAuth-start endpoint allows a global burst of 50 requests and refills five requests per second. Each client can burst five requests and refills one request every 30 seconds. Requests over either limit receive HTTP `429`; reduce retries and investigate abusive or misconfigured clients. Client tracking is capped at `CLIENT_CAPACITY` 4096; saturation returns `429` with `Retry-After: 600`. Pending OAuth state is capped at `STATE_CAPACITY` 2048; saturation returns `429` with `Retry-After: 1`. The limits and both capacities are process-local and reset when the API restarts. Caddy replaces `X-Forwarded-For` with the directly observed client address, and the server trusts only Caddy's fixed `172.30.0.2` address on the private edge network. If a CDN or load balancer is added, redesign and configure trusted-proxy handling instead of accepting arbitrary forwarded-address chains.

## First administrator

After deploying and starting the stack so migrations complete, the intended first operator must sign in with Discord before being promoted from `MEMBER`. In Discord, open **User Settings > Advanced** and enable **Developer Mode**. Then right-click the intended account/user and choose **Copy User ID**. Verify the copied ID belongs to that signed-in account before running:

```sh
sudo docker compose --env-file deploy/.env.production -f compose.production.yml run --rm --no-deps server bootstrap-admin --database-url 'sqlite:///var/lib/acm/db.sqlite?mode=rw' --discord-id '<discord-id>'
```

The existing-file `mode=rw` URL does not create a database. The command creates no user, refuses missing or duplicate matches, and refuses once any administrator exists. Sign out and back in after promotion so the JWT reflects `ADMIN`.

## Backup and restore

Run manual database commands from a checkout with `/usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)"`. The daily systemd job instead uses the `ACM_REPOSITORY_DIR` recorded in `/etc/acm/bootstrap.conf`; see [deployment](../deploy/README.md#backup-restore-and-rollback) for marker, checksum, quarantine, and recovery behavior. The stable helpers remain available after checkout, allowing rollback to continue when the target lacks toolkit files. Test a restore on a non-production copy before an incident.

If deployment leaves failed or prepared state, inspect it before explicitly using the stable helper's [`acknowledge-state`](../deploy/README.md#deployment-state-recovery) recovery command. The command archives evidence and does not perform an automatic rollback, restore, or restart.

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
- **OAuth start returns `429`:** reduce retries and check for abusive or misconfigured clients. `Retry-After: 600` indicates client-tracking capacity saturation. `Retry-After: 1` can indicate global-bucket exhaustion or pending OAuth-state capacity saturation; other per-client and global limits return dynamic retry values. Limits and capacities reset on API restart. If a CDN or load balancer was added, review the trusted-proxy design rather than accepting its forwarded-address chain by default.
