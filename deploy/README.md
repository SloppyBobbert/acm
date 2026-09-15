# Production deployment

[Chico ACM](../README.md) / **Operations**

[First launch](#bootstrap-and-first-launch) · [Updates](#updates) · [Backups and rollback](#backup-restore-and-rollback) · [Smoke checks](#smoke-and-routine-operations) · [Security](#security-checklist)

> [!IMPORTANT]
> For local development, use the [local Compose guide](../README.md#docker-compose). This guide is for production operators and includes commands that change the host and database.

`compose.production.yml` builds Caddy, the API, and Ramiel from the source checkout. Only Caddy exposes application ports 80 and 443. The frontend is deployed separately. Do not substitute GHCR images for this workflow.

Run every production command with `sudo`. Use `/opt/acm` or `/srv/acm` for the checkout, or another normalized absolute path that meets all these trust requirements:

- Every existing ancestor, the checkout, `.git`, deployment inputs, environment file, migrations, and state are root-owned.
- Those paths contain no symlinks and are not group- or world-writable.
- The production environment file has owner `root:root` and mode `0600`.
- Deployment state directories have owner `root:root` and mode `0700`. State files have mode `0600`.

---

## Bootstrap and first launch

### Host requirements

Use an Ubuntu amd64/x86-64 host with a supported native runner kernel. See [Landlock requirements](../crates/ramiel/README.md#docker-platform-support). Prepare a clean, trusted checkout with `sudo`. Configure DNS for the frontend and API hosts, and allow public TCP ports 80 and 443.

Do not commit live domain, account, or secret values. Keep the private production environment file out of Git.

### Bootstrap

Run from the checkout. `--check` changes nothing. An ordinary bootstrap installs Docker, managed directories, and stable helpers under `/usr/local/libexec/acm`. It changes UFW only with `--configure-firewall`. Backups are manual-only. Scheduled backups are unsupported by this workflow.

Before adopting a nonempty managed directory, review its contents. Use `--adopt-existing-paths` only after that review. Bootstrap writes `/etc/acm/bootstrap.conf` as a root-owned file with mode `0600`.

The default managed directories are:

| Purpose | Path |
| --- | --- |
| Database | `/var/lib/acm` |
| Backups | `/var/backups/acm` |
| Restore quarantine | `/var/lib/acm-quarantine` |

```bash
sudo deploy/bootstrap-ubuntu.sh --check
# Choose one bootstrap invocation. This ordinary one does not change UFW.
sudo ACM_REPOSITORY_DIR="$(pwd -P)" ACM_DATA_DIR=/var/lib/acm ACM_BACKUP_DIR=/var/backups/acm ACM_QUARANTINE_DIR=/var/lib/acm-quarantine deploy/bootstrap-ubuntu.sh
# Alternative single bootstrap invocation, only after reviewing host firewall policy:
sudo ACM_REPOSITORY_DIR="$(pwd -P)" ACM_DATA_DIR=/var/lib/acm ACM_BACKUP_DIR=/var/backups/acm ACM_QUARANTINE_DIR=/var/lib/acm-quarantine deploy/bootstrap-ubuntu.sh --configure-firewall
```

### Private environment

Use the checked-in example only as a field reference. Supply the values in [configuration](../docs/configuration.md), including `ACM_DATA_DIR=/var/lib/acm` or another permitted absolute literal path. Do not copy a production environment file as an unprivileged user. `validate` checks the file without printing interpolated secrets.

> [!CAUTION]
> If `deploy/.env.production` already exists, skip the `install` command. That command overwrites its contents. Edit the existing file with `sudoedit` instead.

```bash
sudo install -o root -g root -m 600 /dev/null deploy/.env.production
sudoedit deploy/.env.production
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" validate
```

### First deployment

Use `initial` only on a host with no production SQLite files and no deployment state. After it succeeds, take and verify the first manual backup. `acm-db` writes exactly one `BACKUP_DIR=...` line to stdout. Retain that path.

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" initial '<revision>'
backup_output="$(sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" backup --backup-root /var/backups/acm)"
case "$backup_output" in
  BACKUP_DIR=/*) backup_dir=${backup_output#BACKUP_DIR=} ;;
  *) printf '%s\n' "unexpected backup output: $backup_output" >&2; exit 1 ;;
esac
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" verify --backup-dir "$backup_dir"
```

There is no automated backup or timeout supervisor. Run and supervise each backup manually.

Manual backups and deployment mutations share `/run/acm/acm-operation.lock`. Its directory is `root:root` mode `0700`. Its file is `root:root` mode `0600`. Bootstrap or the first mutating root helper creates or reuses these objects after reboot. Neither changes the global `/run/lock` directory.

## Updates

Every update needs a verified predeployment backup from the current `HEAD`. Its recorded revision and migration identity must match the current checkout. Create the backup, verify it, then deploy the target.

```bash
backup_output="$(sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" backup --backup-root /var/backups/acm)"
case "$backup_output" in
  BACKUP_DIR=/*) backup_dir=${backup_output#BACKUP_DIR=} ;;
  *) printf '%s\n' "unexpected backup output: $backup_output" >&2; exit 1 ;;
esac
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" verify --backup-dir "$backup_dir"
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" deploy '<target>' --backup "$backup_dir"
```

`deploy` requires a clean checkout, an existing local target revision, and the verified matching backup. It detaches at the target revision, builds images, starts services, runs smoke checks, and records state. The installed helpers remain available after checkout.
The installed helpers also support rollback to revisions without toolkit files.

---

## Backup, restore, and rollback

Use the installed `/usr/local/libexec/acm` helpers for all production operations. Include `--repository-dir "$(pwd -P)"` in each invocation. Use repository-local scripts only for the initial bootstrap or check before the installed helpers exist.

A manual backup holds the shared operation lock and stops a running server. It copies the SQLite file set, records the source revision and migration identity, and verifies checksums. The helper changes the backup marker from `INCOMPLETE` to `COMPLETE` only after verification.

If this invocation stopped the server, the helper restarts it after it seals the backup. It then releases the operation lock and prints `BACKUP_DIR=...`. A restart failure returns a nonzero status without that success line. The helper never deletes backups. There is no automatic retention policy.

> [!CAUTION]
> Supervise each backup. Copy, checksum, and Docker commands can hang indefinitely. No automated backup or timeout supervisor is available.
>
> Preserve the output and other evidence. Before recovery, inspect running processes and the relevant container. Do not assume cleanup traps guarantee a restart. Do not kill processes or remove the shared lock as a shortcut.

```bash
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" backup --backup-root /var/backups/acm
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" verify --backup-dir '/var/backups/acm/<backup-directory>'
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" metadata --backup-dir '/var/backups/acm/<backup-directory>'
```

Rollback is prepare-only. The backup's source revision and migration identity must match the rollback target. `rollback` checks this match, then detaches and builds the target. It never starts services, restores data, or runs smoke checks.

Generic `up` refuses an incomplete rollback state. Each prepare, restore, and rollback-start operation takes the shared host lock. State overwrite refusal protects the prepared state across those steps.

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" rollback '<target>' --backup "$backup_dir"
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" restore --backup-dir "$backup_dir" --yes-restore --quarantine-root /var/lib/acm-quarantine
# Confirm the reported quarantine path and restore success before continuing.
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" rollback-start --backup "$backup_dir"
```

Restore verifies a complete backup under the shared lock.
It stops a running server. It moves the current SQLite set into a new quarantine directory on the same filesystem. Restored files have ownership `10001:10001` and mode `0600`.

Restore moves stale SQLite journals and sidecars into quarantine. It never deletes them. An unsafe symlink or nonregular sidecar causes restore to fail.

> [!CAUTION]
> If restore fails, leave the server stopped. Inspect the reported quarantine directory. Move any partially restored files into a separate quarantine location. Move the original SQLite set back before you start the server. Do not overwrite or delete files during recovery.

## Deployment state recovery

Deployment refuses to overwrite a failed or prepared state. Inspect the preserved failed or prepared state. Determine the appropriate operator action. Recovery is never automatic. Only after that review, acknowledge it explicitly:

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" acknowledge-state
```

The command archives the state evidence and records the acknowledgment. It never deletes that evidence. It does not roll back, restore data, or start services.

## Smoke and routine operations

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" status
sudo /usr/local/libexec/acm/smoke.sh --repository-dir "$(pwd -P)" --resolve
sudo docker compose --env-file deploy/.env.production -f compose.production.yml logs -f caddy server ramiel
```

`/usr/local/libexec/acm/smoke.sh` is read-only. Its hard wall-clock deadline is 90 seconds total. Docker status and diagnostic commands use only the remaining time. It waits for Caddy, server, and Ramiel health, then requests the API health endpoint. On the deployment host, `--resolve` routes the API host to `127.0.0.1`. Do not use this option from another host.

## First administrator

After the stack starts and migrations complete, have the intended operator sign in with Discord. Then use the operator's verified Discord user ID:

```bash
sudo docker compose --env-file deploy/.env.production -f compose.production.yml run --rm --no-deps server bootstrap-admin --database-url 'sqlite:///var/lib/acm/db.sqlite?mode=rw' --discord-id '<discord-id>'
```

The command creates no user, promotes only one existing account, and refuses missing or duplicate matches or any existing administrator. Sign out and back in after promotion so the JWT reflects `ADMIN`.

## Security checklist

- Keep `deploy/.env.production` root-owned, mode `0600`, private, and out of Git.
- Use unique production values for `JWT_SECRET` and `DISCORD_SECRET`.
- Set `FRONTEND_ORIGIN` to one exact HTTPS origin.
- Expose only application ports 80 and 443. Restrict administrative access separately.
- Keep Docker and the host patched.
