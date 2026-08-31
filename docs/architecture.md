# Architecture

```text
Browser
  | frontend assets                 | HTTPS / WSS
  v                                 v
Vercel frontend                 Caddy (public :80, :443)
                                      |
                                      v
                                 server (:8081)
                                  |        |
                                  v        v
                             SQLite file  Ramiel (:8082)
                                           C++ -> WASI -> Wasmtime
```

The frontend is deployed separately and uses `NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_WS_URL` for API and WebSocket access. For Discord sign-in, it navigates to the API start endpoint. The API owns `DISCORD_CLIENT_ID`, `DISCORD_REDIRECT_URI`, and `DISCORD_SECRET`; no Discord OAuth value belongs in the frontend environment. Caddy terminates public traffic for the API domain and reverse-proxies it to `server`.

The server owns authentication, competition data, and SQLite migrations. It sends compilation and execution requests to Ramiel over HTTP. Ramiel compiles C++ with the WASI SDK and executes the generated WebAssembly with Wasmtime.

## Jobs and live updates

Long-running submission, custom-input, and test-generation requests enter an in-memory server queue. The worker starts up to `PARALLEL_JOB_COUNT` jobs and records status in an in-memory map. It sends job updates, completion events, and scheduled problem-publication events through an in-process broadcast channel. Authorized officers can connect to `/ws` to receive those events.

The queue, job status map, counters, and broadcast channel are process-local. Restarting the server drops queued work and recent job status. Multiple API replicas do not share queue state or WebSocket events. The job map removes completed entries after ten seconds. SQLite is also a single-file datastore, so this deployment is not designed as a horizontally scaled API tier.

## Trust and network boundaries

- Caddy is the only production container with public ports. The `runner` Docker network is internal; Ramiel is reachable only from the server.
- The browser reaches Caddy, not the server or Ramiel directly. The API allows credentialed CORS requests only from `FRONTEND_ORIGIN`.
- The edge Docker network reserves `172.30.0.0/24`; Caddy has the fixed address `172.30.0.2`. Caddy replaces `X-Forwarded-For` with its directly observed remote host, and the API trusts only that fixed address for client identity.
- The login flow begins when the frontend navigates to the API start endpoint. The API creates a one-time state cookie that expires after five minutes and redirects to Discord. The callback posts its code and state to the API, which validates and consumes the state before exchanging the code.
- OAuth starts have global and per-client limits. Requests over either limit receive HTTP `429`.
- Deploy the frontend and API under one registrable custom domain, such as `app.example.com` and `api.example.com`. Session cookies remain `SameSite=Lax`; a raw unrelated Vercel domain may be treated as a third party and blocked.
- SQLite persists through the server's mounted data directory. It contains application data and must be backed up separately from containers.
- Ramiel processes untrusted competition code. The production Compose file gives it a read-only root filesystem, a writable executable `/tmp` tmpfs, resource limits, and no public network attachment. Those limits reduce exposure; they are not a security guarantee beyond the configured container and runtime boundaries.

## Current constraints

- Ramiel's host-native compiler path is fixed at `/opt/wasi-sdk/bin/clang++`.
- Production Ramiel is amd64 because the image installs the amd64 WASI SDK package.
- The API health endpoint checks that the process responds; it does not prove a job can compile or execute.
- Caddy proxies the API domain only. The frontend remains a separate Vercel deployment.
- Adding a CDN or load balancer requires a redesigned, explicitly configured trusted-proxy setup. Do not accept arbitrary forwarded-address chains.
- Discord requires `DISCORD_REDIRECT_URI` to use the normalized scheme, host, and effective port of `FRONTEND_ORIGIN`, with the `/auth/discord` path and no credentials, query, or fragment. Register that URI in the Discord application. Use HTTPS in production; HTTP is allowed only for insecure localhost development.
