# DigitalOcean, Vercel, and Discord setup

Use this checklist to prepare ACM accounts and domains. Use accounts that you or your organization control.

**Selected plan:** DigitalOcean at $12/month. No live deployment or resource validation on this size is complete.

## 1. Confirm the budget

Prices referenced on 2026-09-09, in USD:

| Item | Cost |
| --- | --- |
| DigitalOcean Basic Regular: 1 vCPU, 2 GiB RAM, 50 GiB disk | $12/month |
| Vercel Hobby, for eligible personal, non-commercial use | $0 |
| Standard domain, estimated allowance | $10–20/year |
| Discord OAuth, SQLite, Caddy, and HTTPS certificates | No separate fee |
| Monthly equivalent, before tax | About $12.83–13.67 |

The domain bill is annual. Taxes, excess traffic, and paid backups are additional costs. A public IPv4 address is included.

**CAUTION: Review resource limits before purchase or launch.** The current deployment builds Rust images on the server.
Current Compose limits allow Ramiel 2 CPUs and 2 GiB RAM, plus 512 MiB RAM for the API.
These are ceilings, not reserved memory. The selected host has only 1 CPU and 2 GiB RAM in total.
Adjust the limits through a separate approved configuration change. Then validate builds, disk use, and real jobs.

- [ ] Confirm whether Vercel Hobby permits your use. An organization or club site does not automatically qualify.
- [ ] Complete resource validation, or explicitly approve a short paid trial with reviewed limits.
- [ ] Review the current checkout price before any purchase or upgrade.

The $12 server replaces the earlier under-$10 target. No server purchase or resize is part of this document change.
Building images elsewhere requires a separate deployment change.

## 2. Understand the stack and choose a domain

This is the planned hosting layout, not a live deployment. Replace `example.com` with your domain.

| Component | Technology and function | Host |
| --- | --- | --- |
| Frontend, `lilith/` | Next.js 12.3.7, React 18.3.1, TypeScript 4.9.5, Tailwind CSS | Vercel: `https://app.example.com` |
| Browser features | Monaco editor and Vim bindings, Zustand state, SWR data fetching, Sigma/Graphology graphs, React Spring, Marked, KaTeX | Browser, from Vercel assets |
| API, `crates/server/` | Rust, Axum 0.6, Tokio, Serde, SQLx 0.8, JWT authentication | DigitalOcean container: private port `8081` |
| Public API entry | Caddy reverse proxy and HTTPS certificates | DigitalOcean container: public ports `80` and `443` |
| Database | SQLite file at `/var/lib/acm/db.sqlite`, through SQLx | Persistent DigitalOcean disk, not Vercel or a managed database |
| Runner, `crates/ramiel/` | Rust service, C++ compilation with WASI SDK 19, WebAssembly execution with Wasmtime 44 | DigitalOcean container: private port `8082` |
| Jobs and live updates | API in-memory queue and WebSocket broadcast | API process on DigitalOcean, without Redis |
| Login identity | Discord OAuth2, with code exchange and session creation in the API | Discord plus the DigitalOcean API |
| Build and runtime tools | Rust 1.92 image builder, Debian Bookworm containers, Docker Compose, Ubuntu 24.04 amd64 host | DigitalOcean |
| Frontend build tools | Node.js 22 and Yarn Classic 1.22.22 | Vercel build environment |
| Source and checks | Git repository and GitHub Actions validation/build jobs | GitHub, not the application runtime |
| DNS | `app` points to Vercel, `api` points to the Droplet | Your chosen DNS provider |

The browser loads the frontend from Vercel, then calls `https://api.example.com` through Caddy.
Caddy forwards HTTP and `wss://api.example.com/ws` to the API. The API uses SQLite and sends jobs to Ramiel.
Discord returns login to `https://app.example.com/auth/discord`. The frontend passes the code to the API for verification.
Use both subdomains under one registrable domain for session cookies. An unrelated `vercel.app` address is not the production login configuration.
See [architecture.md](architecture.md) for network boundaries and queue limitations.

- [ ] Register the domain with your preferred registrar.
- [ ] Review both registration and renewal prices.
- [ ] Enable automatic renewal.
- [ ] Enable two-factor authentication for the registrar, GitHub, DigitalOcean, Vercel, and Discord accounts.
- [ ] Store recovery codes and credentials in a password manager.
- [ ] Keep DNS management at one provider.

**CAUTION: Keep passwords, private SSH keys, and application secrets out of chat and Git.** Use only placeholders in shared notes.

## 3. Prepare DigitalOcean

1. Open [DigitalOcean](https://cloud.digitalocean.com/).
2. Create your account.
3. Create a project named `acm`.
4. When DigitalOcean requires billing details, add them privately.
5. Configure available billing alerts.

Billing alerts are notifications, not a guaranteed spending cap.

### Prepare an SSH key on your Mac

Use an existing suitable key, or create a dedicated key.
**CAUTION: Do not overwrite an existing SSH key.** If `~/.ssh/acm_do` already exists, choose another filename in every command.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/acm_do -C "acm-production"
```

1. When the command requests a passphrase, set one.
2. Copy the public key to the clipboard:

```bash
pbcopy < ~/.ssh/acm_do.pub
```

3. Open DigitalOcean's SSH key settings.
4. Select **Add SSH Key**.
5. Paste the public key.
6. Save the key with a descriptive name.

Upload only the `.pub` file. Keep the private key on your Mac.

### Create the Droplet after the resource review

Continue only after resource validation or approval for a short paid trial with reviewed limits.

1. Select **Create → Droplets**.
2. Select a region near your users.
3. Select these settings:

| Setting | Selection |
| --- | --- |
| Image | Plain Ubuntu 24.04 LTS |
| Architecture | amd64 / x86-64, not ARM |
| Plan | Basic shared CPU, Regular |
| Selected size | $12/month: 1 vCPU, 2 GiB RAM, 50 GiB disk |
| Authentication | Your SSH key |
| Hostname | `acm-production` |
| Quantity | One |

4. Review optional charges before creation.
5. Leave paid backup scheduling disabled for this initial trial.
6. Confirm the displayed price.
7. Create the Droplet.
8. Record its public IPv4 address privately.

Do not add a managed database, Kubernetes cluster, or load balancer.
The existing deployment uses SQLite on the server.

### Restrict network access

1. Create a DigitalOcean Cloud Firewall.
2. Attach it to the Droplet.
3. Set these inbound rules:

| Protocol | Port | Allowed source |
| --- | --- | --- |
| TCP | 22 | Your administrator public IPv4 address only |
| TCP | 80 | All IPv4 addresses |
| TCP | 443 | All IPv4 addresses |

4. Keep outbound traffic allowed for DNS, package downloads, Discord, and certificate requests.
5. Keep API port `8081` and Ramiel port `8082` private.

If your administrator IP changes, update the SSH rule before reconnecting.
If you enable IPv6, review its firewall rules separately.
DigitalOcean Cloud Firewall and Ubuntu UFW are separate controls. Review host hardening before public launch.

Replace `YOUR_DROPLET_IP` with the public IPv4 address:

```bash
ssh -i ~/.ssh/acm_do root@YOUR_DROPLET_IP
```

Verify the host fingerprint through the DigitalOcean console before accepting it.
Confirm that SSH opens a shell on the correct server.

## 4. Create the Discord application

1. Open the [Discord Developer Portal](https://discord.com/developers/applications).
2. Select **New Application**.
3. Enter the name users will see during login.
4. Select an owner or team that you control.
5. Open **OAuth2**.
6. Add `https://app.example.com/auth/discord`, with your domain, as the exact redirect URI.
7. Save the redirect URI.
8. Record the **Client ID** privately.
9. Store the **Client Secret** in your password manager.

The callback belongs to the frontend, not the API hostname.
This login flow does not require a bot token, bot invitation, or privileged intents.

## 5. Configure Vercel

If your use does not qualify for Hobby, stop before selecting a paid plan.
A paid Vercel plan exceeds this budget. Another frontend arrangement requires a separate review.

1. Open [Vercel](https://vercel.com/).
2. Create your account.
3. Connect your GitHub account.
4. Grant access to `SloppyBobbert/acm`.
5. Select **Add New → Project**.
6. Import the repository.
7. Apply these settings:

| Setting | Value |
| --- | --- |
| Framework Preset | Next.js |
| Root Directory | `lilith` |
| Production Branch | `main` |
| Node.js Version | `22.x`, matching CI |
| Install Command | `corepack yarn@1.22.22 install --frozen-lockfile` |
| Build Command | `corepack yarn@1.22.22 build` |
| Output Directory | Keep the Next.js default |

These commands run inside `lilith`. Keep the Monaco configuration unchanged. Node.js settings are under **Settings → Build and Deployment**.

Under **Settings → Environment Variables**, add these values for **Production**:

```dotenv
NEXT_PUBLIC_API_URL=https://api.example.com
NEXT_PUBLIC_WS_URL=wss://api.example.com/ws
```

**CAUTION: Do not add Discord or JWT secrets to Vercel.** Values with `NEXT_PUBLIC_` are public browser configuration.

1. Deploy the frontend.
2. Inspect the build result.
3. After any build-time variable change, redeploy the frontend.

If Vercel reports a security or compatibility error, stop and preserve the error text.
Do not bypass the check. A successful local build does not prove that Vercel accepts the deployment.
Login and API features remain unavailable until the backend works.

## 6. Configure DNS and HTTPS

1. Open Vercel **Settings → Domains**.
2. Add `app.example.com` with your domain.
3. Copy the exact DNS target Vercel displays.
4. At your DNS provider, create these records:

| Type | Name | Target |
| --- | --- | --- |
| CNAME | `app` | The exact target from Vercel |
| A | `api` | Your Droplet's public IPv4 address |

5. If Vercel requests an ownership TXT record, add that exact record.
6. Wait until Vercel reports valid domain configuration.

Do not copy a CNAME target from another project.
If conflicting DNS records exist, review them before removal.
Do not add an API AAAA record until IPv6 works correctly.
If you use Cloudflare DNS, keep the API record **DNS only**.
A CDN proxy requires a separate review of trusted-proxy handling.
Vercel manages frontend HTTPS. Caddy manages API HTTPS after backend deployment.

From your Mac, verify the DNS answers with your domain:

```bash
dig +short app.example.com
dig +short api.example.com
```

The frontend must resolve through Vercel. The API must resolve to the Droplet.

## 7. Prepare backend configuration and launch

Use [configuration.md](configuration.md) for the server variables. Do not open the protected environment example.

| Variable | Required value |
| --- | --- |
| `API_DOMAIN` | `api.example.com`, without `https://` |
| `FRONTEND_ORIGIN` | `https://app.example.com` |
| `DISCORD_REDIRECT_URI` | `https://app.example.com/auth/discord` |
| `DISCORD_CLIENT_ID` | Your new application client ID |
| `DISCORD_SECRET` | Your new application client secret |
| `JWT_SECRET` | A new secret from at least 32 cryptographically random bytes |
| `ACM_DATA_DIR` | `/var/lib/acm` |
| `PARALLEL_JOB_COUNT` | `1` initially |

Use hexadecimal text for `JWT_SECRET`: 32 random bytes produce 64 characters.
Keep production values in the private server environment file, outside tracked Git content.

- [ ] Prepare a clean, root-owned checkout at `/opt/acm`.
- [ ] Select an explicitly approved, verified revision.
- [ ] Run the nonmutating bootstrap `--check` procedure.
- [ ] Review the host resource limits and firewall policy before installation.
- [ ] Run bootstrap to install Docker, managed directories, and stable helpers.
- [ ] If `deploy/.env.production` does not exist, create it as `root:root`, mode `0600`.
- [ ] Enter the private values with `sudoedit`.
- [ ] Run the installed deployment helper's `validate` command.
- [ ] Use `initial` only with no production SQLite files and no deployment state.

Use the exact commands in [the production runbook](../deploy/README.md#bootstrap-and-first-launch).
Run production commands with `sudo` and an explicit `--repository-dir` for installed helpers.
Preserve the root ownership and path checks. Do not substitute registry images or copy an old database.

## 8. Verify the launch

- [ ] Confirm healthy Caddy, API, and Ramiel services with the runbook's smoke command.
- [ ] Confirm valid HTTPS for both public hostnames.
- [ ] Take and verify the first supervised manual backup.
- [ ] Sign in with the intended administrator's Discord account.
- [ ] Promote that existing account with the runbook's `bootstrap-admin` command.
- [ ] Sign out and back in to obtain the administrator token.
- [ ] Confirm authenticated WebSocket updates.
- [ ] Run one real submission through Ramiel.
- [ ] Check memory and disk use during builds and jobs.
- [ ] Keep a protected backup copy outside the Droplet.
- [ ] Rehearse a restore on a non-production copy before accepting production readiness.

**CAUTION: Supervise every manual backup.** A backup can hang while the API is stopped.
No automatic timeout supervisor exists. Keep application backup scheduling disabled.
Do not remove the shared operation lock or kill processes as a recovery shortcut.
Use the [backup and recovery procedure](../deploy/README.md#backup-restore-and-rollback).

Report only non-secret setup details. Next: review resource limits and validate the $12 Droplet before production launch.

## Provider references

- DigitalOcean: [prices](https://www.digitalocean.com/pricing/droplets), [Droplets](https://docs.digitalocean.com/products/droplets/how-to/create/), [firewalls](https://docs.digitalocean.com/products/networking/firewalls/how-to/configure-rules/).
- Vercel: [Hobby restrictions](https://vercel.com/docs/plans/hobby), [build settings](https://vercel.com/docs/deployments/configure-a-build), [Node.js](https://vercel.com/docs/functions/runtimes/node-js/node-js-versions), [domains](https://vercel.com/docs/domains/working-with-domains/add-a-domain).
- Discord: [OAuth2](https://docs.discord.com/developers/topics/oauth2).
