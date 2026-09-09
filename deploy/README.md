# Production deployment

The source checkout is the canonical deployment input: `compose.production.yml` builds Caddy, server, and Ramiel on the host. Caddy alone exposes 80/443. Do not substitute GHCR images for this workflow.

`/opt/acm` and `/srv/acm` are recommended production checkout locations, not exclusive ones. Any other normalized absolute checkout path is permitted only in the production trust lane: every existing ancestor, the checkout, `.git`, deployment inputs, environment, migrations, and state are root-owned, non-symlinked, and not group- or world-writable. The production environment file is `root:root` mode `0600`; deployment state directories are `root:root` mode `0700` and state files mode `0600`. Run every production command with `sudo`.

## Bootstrap and first launch

Use an Ubuntu amd64/x86-64 host, a clean checkout (prefer `/opt/acm` or `/srv/acm`), DNS for your frontend and API hosts, and public TCP ports 80 and 443. An alternate checkout path is allowed only when it satisfies the production trust lane above. Prepare or clone the production checkout with `sudo`. Do not put live domain, account, or secret values in the checkout.

Run from the checkout. `--check` changes nothing. An ordinary bootstrap installs Docker, managed directories, and stable deploy/database/smoke helpers under `/usr/local/libexec/acm`. It does **not** change UFW unless `--configure-firewall` is supplied. It installs no backup scheduler: backups are manual-only and scheduled backups are deferred. Managed nonempty directories need explicit reviewed adoption with `--adopt-existing-paths`. Bootstrap writes root-owned `0600` `/etc/acm/bootstrap.conf`; its default data, backup, and quarantine roots are `/var/lib/acm`, `/var/backups/acm`, and `/var/lib/acm-quarantine`.

```bash
sudo deploy/bootstrap-ubuntu.sh --check
# Choose one bootstrap invocation. This ordinary one does not change UFW.
sudo ACM_REPOSITORY_DIR="$(pwd -P)" ACM_DATA_DIR=/var/lib/acm ACM_BACKUP_DIR=/var/backups/acm ACM_QUARANTINE_DIR=/var/lib/acm-quarantine deploy/bootstrap-ubuntu.sh
# Alternative single bootstrap invocation, only after reviewing host firewall policy:
sudo ACM_REPOSITORY_DIR="$(pwd -P)" ACM_DATA_DIR=/var/lib/acm ACM_BACKUP_DIR=/var/backups/acm ACM_QUARANTINE_DIR=/var/lib/acm-quarantine deploy/bootstrap-ubuntu.sh --configure-firewall
```

Create the root-owned `deploy/.env.production` with `sudoedit`, using the checked-in example only as a field reference. Supply the values in [configuration](../docs/configuration.md), including the required normalized absolute literal path `ACM_DATA_DIR=/var/lib/acm`. Do not copy a production environment file as an unprivileged user. `validate` checks it without printing interpolated secrets.

```bash
sudo install -o root -g root -m 600 /dev/null deploy/.env.production
sudoedit deploy/.env.production
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" validate
```

Only a host with no production SQLite files and no deployment state may use `initial`. After it succeeds, take and verify the first manual backup. `acm-db` writes exactly one `BACKUP_DIR=...` line to stdout; retain that path.

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" initial '<revision>'
backup_output="$(sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" backup --backup-root /var/backups/acm)"
case "$backup_output" in
  BACKUP_DIR=/*) backup_dir=${backup_output#BACKUP_DIR=} ;;
  *) printf '%s\n' "unexpected backup output: $backup_output" >&2; exit 1 ;;
esac
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" verify --backup-dir "$backup_dir"
```

There is no automated backup or timeout supervisor. Run and supervise each backup manually; scheduled backups are deferred.

Manual backups and deployment mutations share `/run/acm/acm-operation.lock`. Its directory is `root:root` mode `0700` and its file is `root:root` mode `0600`. Bootstrap or the first mutating root helper creates or reuses these objects after reboot; neither changes the global `/run/lock` directory.

## Updates

Every update needs a verified predeployment backup made while the current checkout was at `HEAD`; its recorded revision and migration identity must match that checkout. Capture, verify, then deploy the target.

```bash
backup_output="$(sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" backup --backup-root /var/backups/acm)"
case "$backup_output" in
  BACKUP_DIR=/*) backup_dir=${backup_output#BACKUP_DIR=} ;;
  *) printf '%s\n' "unexpected backup output: $backup_output" >&2; exit 1 ;;
esac
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" verify --backup-dir "$backup_dir"
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" deploy '<target>' --backup "$backup_dir"
```

`deploy` requires a clean checkout, an existing local target revision, and that verified matching backup. It detaches at the target, builds, starts, smokes, and records state. The stable helpers remain available after checkout, so rollback can continue even when the target revision does not contain toolkit files.

## Backup, restore, and rollback

All production helper invocations use the stable `/usr/local/libexec/acm` copies and include `--repository-dir "$(pwd -P)"`. Repository-local scripts are only appropriate for the initial bootstrap or check before those helpers exist. A manual backup stops a running server, holds the shared host operation lock with deployment, copies a consistent SQLite set, records source revision and migration identity in metadata, and verifies checksums. After verifying and sealing the backup, the helper restarts the server only if this invocation stopped it, releases the operation lock, and prints `BACKUP_DIR=...` to stdout; a restart failure returns nonzero without printing that success line. `INCOMPLETE` remains during copying and becomes `COMPLETE` only after verification. Backups have no retention policy and are never deleted by the helper.

> **Warning:** Copy, checksum, and Docker commands can hang indefinitely. No automated backup or timeout supervisor is available. An operator must supervise the backup, preserve its output and other evidence, and inspect running processes and the relevant container before deciding on recovery. Do not assume cleanup traps guarantee a restart, and do not kill processes or remove the shared lock as a shortcut.

```bash
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" backup --backup-root /var/backups/acm
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" verify --backup-dir '/var/backups/acm/<backup-directory>'
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" metadata --backup-dir '/var/backups/acm/<backup-directory>'
```

Rollback is prepare-only. The target backup must have been created while that target revision and its migrations were current. `rollback` checks this match, detaches and builds the target, but never starts services, restores data, or runs smoke. Generic `up` refuses an incomplete rollback state. Each prepare, restore, and rollback-start operation takes the shared host lock; state overwrite refusal protects the prepared state across those steps.

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" rollback '<target>' --backup "$backup_dir"
sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)" restore --backup-dir "$backup_dir" --yes-restore --quarantine-root /var/lib/acm-quarantine
# Confirm the reported quarantine path and restore success before continuing.
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" rollback-start --backup "$backup_dir"
```

Restore verifies a complete backup under the shared lock, stops the server only if necessary, moves the current SQLite set into a new same-filesystem quarantine directory, and restores ownership `10001:10001` with mode `0600`. Stale SQLite journals and sidecars are quarantined, never deleted; an unsafe symlink or nonregular sidecar causes restore to fail. If restore fails, the server remains stopped. Inspect the reported quarantine directory; quarantine any partial restored files separately, move the original set back, and only then start the server. Do not overwrite or delete files during recovery.

## Deployment state recovery

Deployment refuses to overwrite a failed or prepared state. Inspect the preserved failed or prepared state and determine the appropriate operator action; recovery is never automatic. Only after that review, acknowledge it explicitly:

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" acknowledge-state
```

The command archives the state evidence and records the acknowledgment; it never deletes that evidence. It does not roll back, restore data, or start services.

## Smoke and routine operations

```bash
sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)" status
sudo /usr/local/libexec/acm/smoke.sh --repository-dir "$(pwd -P)" --resolve
sudo docker compose --env-file deploy/.env.production -f compose.production.yml logs -f caddy server ramiel
```

`/usr/local/libexec/acm/smoke.sh` is read-only. Its hard wall-clock deadline is 90 seconds total; Docker status and diagnostic commands are bounded to the remaining budget. It waits for Caddy, server, and Ramiel health, then requests the API health endpoint. `--resolve` routes the API host to `127.0.0.1` only when run on the deployment host.

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
- Expose only application ports 80 and 443; restrict administrative access separately.
- Keep Docker and the host patched.
