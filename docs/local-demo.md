# Local demo before hosting

No hosting account is needed. Use the real API and frontend. Do not use simulated compiler responses outside tests.

## 1. Start locally

### Use Docker Compose with an existing root `.env`

This is the complete local setup. It starts the frontend, API, and Ramiel without a host Rust or Node installation. Docker builds images for its native amd64 or arm64 architecture. The production setup remains separate in `compose.production.yml`.

1. Start Docker Desktop with Linux containers, or Docker Engine on Linux. Use Docker Compose 2.39.0 or later. The Docker Linux kernel must enforce Landlock ABI 3 or later. Do not force amd64 emulation on an ARM64 machine.
2. Open a terminal in the repository root. Stop any existing services on ports 3000 and 8081.
3. Keep valid `JWT_SECRET`, `DISCORD_CLIENT_ID`, and `DISCORD_SECRET` values in the root `.env`. Register `http://127.0.0.1:3000/auth/discord` in your Discord application. Keep `.env` untracked.
4. Start the app:

   ```sh
   docker compose up --build
   ```

   For later starts without code changes, use `docker compose up`. Use `--build` after code changes. The frontend uses development mode. Source files are copied into the image, not mounted from your checkout.

   The first build downloads images and dependencies and can use several GB of disk space. Sources include Docker Hub (`node`, `rust`, and `debian`), Debian package repositories, crates.io, and the package sources in the lockfiles. The runner also downloads toolchains from Rust distribution servers and the WebAssembly WASI SDK release on GitHub.

5. Open **<http://127.0.0.1:3000>**, not `localhost`. Check the API from another terminal:

   ```sh
   curl --fail http://127.0.0.1:8081/healthz
   docker compose ps
   ```

6. Stop the app with Ctrl-C. To remove the stopped containers without removing the database, use `docker compose down`.

**Data:** Compose uses the separate `acm-local_local_data` volume. It does not use your host `DATABASE_URL` or import an existing SQLite file. The API creates the database and applies migrations. Do not use `docker compose down --volumes` unless you intend to delete this database.

**Configuration:** Compose reads only the three required secret/client values listed above. Local ports, browser URLs, the redirect URI, and cookie settings are fixed in `compose.yml`. The server uses `http://ramiel:8082` inside Docker. Browser requests use `http://127.0.0.1:8081`. No real environment file enters the build context.

**Environment file elsewhere:** Use `docker compose --env-file /absolute/path/to/your.env up --build`. Use the same `--env-file` option for later Compose commands, including logs and administrator setup. Do not copy secrets into the repository to change their location.

**Logs:** Use `docker compose logs --tail=100 server frontend ramiel`. Keep logs private if they contain application data. Do not share `docker compose config` output because it can contain secrets.

**Runner:** Ramiel starts by default. The API waits for runner health, and the frontend waits for API health. The runner has no host port. Compiler isolation, a read-only root filesystem, and resource limits remain active. If isolation is unavailable, startup fails. Do not disable security controls to bypass this failure. See the [runner support matrix](../crates/ramiel/README.md#docker-platform-support) for platform evidence.

For a startup check that waits for all services, use `docker compose up --build --detach --wait --wait-timeout 300`. The frontend health check waits for an actual page response. Initial builds can take much longer than subsequent starts.

A new volume contains no users or problems. Continue with section 2 after a real Discord login. GitHub sample files do not populate the database automatically.

### Alternative: use an existing root `.env` without Docker on macOS

This path starts the API and frontend directly on your Mac, without Docker. It does not start Ramiel. Run/Submit need a separately managed, supported runner.

1. Check the prerequisites: a current stable Rust toolchain, Node.js with Corepack, and the macOS C/C++ build tools.

   ```sh
   cargo --version
   node --version
   corepack --version
   clang --version
   ```

2. Open a terminal in the repository root. Keep ports 3000 and 8081 free. Stop an existing local session before you start another.
3. Keep your existing `.env` secrets. Set these non-secret values in the root `.env`:

   ```dotenv
   DEV_START_RAMIEL=false
   API_HOSTNAME=127.0.0.1
   PORT=8081
   FRONTEND_PORT=3000
   FRONTEND_ORIGIN=http://127.0.0.1:3000
   DISCORD_REDIRECT_URI=http://127.0.0.1:3000/auth/discord
   COOKIE_SECURE=false
   NEXT_PUBLIC_API_URL=http://127.0.0.1:8081
   NEXT_PUBLIC_WS_URL=ws://127.0.0.1:8081/ws
   ```

   Keep `DATABASE_URL` if it points to your existing local database. For a new database in the repository root, use `DATABASE_URL=sqlite://./db.sqlite`. Do not use a production database. The API applies migrations at startup.

   Login requires valid `DISCORD_CLIENT_ID`, `DISCORD_SECRET`, and `JWT_SECRET` values. Register `http://127.0.0.1:3000/auth/discord` as a redirect URI in your Discord application. Keep `.env` untracked. Never put secrets in `NEXT_PUBLIC_*` variables.

4. Start the app:

   ```sh
   DEV_ENV_FILE="$PWD/.env" SQLX_OFFLINE=true ./scripts/dev-local.sh
   ```

   The script loads `.env`, builds the API, and creates the SQLite file if needed. It installs frontend dependencies if `lilith/node_modules` is absent. The first run can download dependencies and use several GB of disk space. Cargo uses crates.io and any Git sources in `Cargo.lock`. Yarn uses the package sources in `lilith/yarn.lock`. `SQLX_OFFLINE` disables database access during SQLx compilation, not network downloads.

5. Open **<http://127.0.0.1:3000>**, not `localhost`. Check the API from another terminal:

   ```sh
   curl --fail http://127.0.0.1:8081/healthz
   ```

   API health does not prove login or code execution. API logs are in `.local/logs/server.log`. Frontend logs appear in the startup terminal.

6. Stop the app with Ctrl-C. Repeat step 4 for later starts.

A new database contains no practice problems. Continue with section 2 to import them after login. Files on GitHub do not populate the database automatically.

### Alternative: use an isolated local database

Requirements: Rust/Cargo, Node.js with Corepack, and SQLite. Run from the repository root. Keep ports 3000 and 8081 free. Use this alternative instead of the root `.env` procedure above.

Create a new directory once. This preserves the root `.env`, existing databases, and local tool files:

```sh
mkdir -p .local
DEMO_DIR="$(mktemp -d "$PWD/.local/demo.XXXXXX")"
cp .env.example "$DEMO_DIR/demo.env"
chmod 600 "$DEMO_DIR/demo.env"
printf '\nDATABASE_URL="sqlite://%s/db.sqlite"\nDEV_START_RAMIEL=false\nFRONTEND_PORT=3000\nNEXT_PUBLIC_API_URL=http://127.0.0.1:8081\nNEXT_PUBLIC_WS_URL=ws://127.0.0.1:8081/ws\n' "$DEMO_DIR" >> "$DEMO_DIR/demo.env"
printf 'Keep this path for later runs: %s\n' "$DEMO_DIR"
DEV_ENV_FILE="$DEMO_DIR/demo.env" ./scripts/dev-local.sh
```

Open **<http://127.0.0.1:3000>**, not `localhost`. The script builds the API with offline SQLx metadata and applies migrations at startup. `DEV_START_RAMIEL=false` skips the runner; it does not replace it. Logs are in `.local/logs/`.

If you change `FRONTEND_PORT`, also update `FRONTEND_ORIGIN` and `DISCORD_REDIRECT_URI` in `$DEMO_DIR/demo.env`. The copied `.env.example` fixes both values at port 3000. For example, port 3101 needs `http://127.0.0.1:3101` and `http://127.0.0.1:3101/auth/discord`. Alternatively, omit both variables from the file and unset them in the shell so the script derives them. Update the registered Discord redirect and the browser URLs below to match. No change is needed for the default port 3000 procedure.

For later runs, set `DEMO_DIR` to the saved path and repeat only the last command. Do not copy the example again. Stop with Ctrl-C. No step deletes or replaces the database.

Check the API in another terminal:

```sh
curl --fail http://127.0.0.1:8081/healthz
```

A successful response proves only API health. It does not prove compilation, execution, or login. With an empty database, the home page shows **No featured problem yet**. The problem list is empty.

## 2. Import the samples after a real login

The existing `POST /problems/new` path accepts complete tests and expected results. A new seed command is not needed. It requires an officer or administrator. Sample import remains blocked until a real login is available.

1. Register a development Discord OAuth application with redirect URI `http://127.0.0.1:3000/auth/discord`.
2. Set its client ID and secret in your chosen environment file: root `.env` or isolated `$DEMO_DIR/demo.env`. Do not put secrets in public frontend variables or commit the file.
3. Restart the local script, then sign in with Discord.
4. For the first administrator only, verify your Discord user ID. Use the existing bootstrap tool with the same database as the API.

   For Docker Compose:

   ```sh
   docker compose exec server bootstrap-admin \
     --database-url 'sqlite:///var/lib/acm/db.sqlite?mode=rw' \
     --discord-id '<your-verified-discord-user-id>'
   ```

   For the isolated host database:

   ```sh
   SQLX_OFFLINE=true cargo run --locked -p server --bin bootstrap-admin -- \
     --database-url "sqlite://$DEMO_DIR/db.sqlite?mode=rw" \
     --discord-id '<your-verified-discord-user-id>'
   ```

   For the root `db.sqlite` database, replace the database URL above with `"sqlite://./db.sqlite?mode=rw"`. If your `.env` uses a different local database path, use that path instead. Do not run both commands.

   This promotes an existing user. It creates no user and refuses an existing administrator. Sign out and back in.

5. Open the browser console on `http://127.0.0.1:3000`. Run this local-only call to the existing creation API. Select `add.json` and `larger.json` from `docs/examples/local-demo/`:

   ```js
   if (location.origin !== 'http://127.0.0.1:3000') throw new Error('Open the local demo first.');
   const picker = document.createElement('input');
   picker.type = 'file'; picker.multiple = true; picker.accept = '.json';
   picker.onchange = async () => {
     for (const file of picker.files) {
       const response = await fetch('http://127.0.0.1:8081/problems/new', {
         method: 'POST', credentials: 'include',
         headers: { 'Content-Type': 'application/json' }, body: await file.text()
       });
       const result = await response.json();
       if (!response.ok) throw new Error(`${file.name}: ${response.status} ${result.error}`);
       console.log(file.name, `/problems/${result.id}`);
     }
   };
   picker.click();
   ```

Import once per demo database. The endpoint appends problems; it does not replace existing ones. If an import partly fails, select only the file that failed. Never target a production API or database. This procedure uses the browser's real session cookie; do not export cookies or manufacture a token.

For five more practice problems, repeat the import step and select only `digit-sum.json`, `reverse-digits.json`, `greatest-common-divisor.json`, `fibonacci.json`, and `steps-to-zero.json`. These are original exercises, not copied LeetCode content. Each file includes constraints, a C++ template, a reference answer, and expected test results. Pushing these files to GitHub does not import them into a database.

The two initial samples cover addition and comparison, including negative and equal inputs. Each description contains complete C++ and Rust answers and three expected results. The creation API stores a C++ reference and template; the existing Rust-template endpoint derives the Rust signature from the tests. Inputs and outputs are typed function values, not stdin/stdout. Fuel values are unset; existing runner defaults apply. These examples do not establish resource limits or compiler acceptance.

## 3. Repeat the browser demo

After import, open **Problems** and select each sample:

- Edit C++, change to Rust, and edit Rust. Reload, then switch languages again. Each saved draft must remain separate.
- Navigate to the other problem and back. Check that its code remains separate.
- In a fresh browser profile, **Settings > Inline code checks** must be off. Do not clear a user's browser storage to reset it.
- Enable checks. Enter invalid syntax, then restore the example. Disable checks and confirm the inline markers disappear.
- Try checks off/on with Vim off/on. Check that the editor and footer remain usable in all four combinations.
- Without login, Run/Submit must request login. With login but no supported runner, failures must remain visible. Neither result is compiler acceptance.

For a repeatable browser check without login or a populated database, use the existing [simulated API browser test](testing.md#inline-editor-diagnostics). It uses real editor assets but simulated problem, login, job, and compiler responses. This is a test, not a replacement demo backend.

## 4. Real compiler prerequisites

Real logged-in Run/Submit acceptance still requires:

- A real development Discord login and the imported local samples.
- A native amd64 or arm64 Linux container with Landlock ABI 3 or later, plus the documented [runner toolchains and helper](../crates/ramiel/README.md).
- Ramiel reachable at `RAMIEL_URL`. Set `DEV_START_RAMIEL=true` to let the local script start it on a supported host. Keep it false if a separately managed supported runner is already available.
- Successful and deliberately invalid C++ and Rust through **both Run and Submit**, with expected test results and visible compiler errors.

Image builds, `/healthz`, and simulated responses alone cannot satisfy that final acceptance. Apple Silicon must use native arm64 containers, not Rosetta. Do not change isolation, flags, or authentication to make a demo pass.

## Verification record

See [local demo verification](local-demo-verification.md) for the exact checks and remaining blocks.
