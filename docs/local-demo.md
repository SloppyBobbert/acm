# Local demo before hosting

No hosting account is needed. Use the real API and frontend. Do not use simulated compiler responses outside tests.

## 1. Start an isolated local database

Requirements: Rust/Cargo, Node.js with Corepack, and SQLite. Run from the repository root. Keep ports 3000 and 8081 free.

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

Open **http://127.0.0.1:3000**, not `localhost`. The script builds the API with offline SQLx metadata and applies migrations at startup. `DEV_START_RAMIEL=false` skips the runner; it does not replace it. Logs are in `.local/logs/`.

For later runs, set `DEMO_DIR` to the saved path and repeat only the last command. Do not copy the example again. Stop with Ctrl-C. No step deletes or replaces the database.

Check the API in another terminal:

```sh
curl --fail http://127.0.0.1:8081/healthz
```

A successful response proves only API health. It does not prove compilation, execution, or login. With an empty database, the home page shows **No featured problem yet**. The problem list is empty.

## 2. Import the samples after a real login

The existing `POST /problems/new` path accepts complete tests and expected results. A new seed command is not needed. It requires an officer or administrator. Sample import remains blocked until a real login is available.

1. Register a development Discord OAuth application with redirect URI `http://127.0.0.1:3000/auth/discord`.
2. Set its client ID and secret in the private `$DEMO_DIR/demo.env`. Do not put secrets in public frontend variables or commit the file.
3. Restart the local script, then sign in with Discord.
4. For the first administrator only, verify your Discord user ID and use the existing bootstrap tool:

   ```sh
   SQLX_OFFLINE=true cargo run --locked -p server --bin bootstrap-admin -- \
     --database-url "sqlite://$DEMO_DIR/db.sqlite?mode=rw" \
     --discord-id '<your-verified-discord-user-id>'
   ```

   This promotes an existing user. It creates no user and refuses an existing administrator. Sign out and back in.

5. Open the browser console on `http://127.0.0.1:3000`. Run this local-only call to the existing creation API. Select **both JSON files** from `docs/examples/local-demo/`:

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

The two samples cover addition and comparison, including negative and equal inputs. Each description contains complete C++ and Rust answers and three expected results. The creation API stores a C++ reference and template; the existing Rust-template endpoint derives the Rust signature from the tests. Inputs and outputs are typed function values, not stdin/stdout. Fuel values are unset; existing runner defaults apply. These examples do not establish resource limits or compiler acceptance.

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
- Native Linux amd64 with Landlock ABI 3 or later, plus the documented [runner toolchains and helper](../crates/ramiel/README.md).
- Ramiel reachable at `RAMIEL_URL`. Set `DEV_START_RAMIEL=true` to let the local script start it on a supported host. Keep it false if a separately managed supported runner is already available.
- Successful and deliberately invalid C++ and Rust through **both Run and Submit**, with expected test results and visible compiler errors.

Apple Silicon, Rosetta, image builds, `/healthz`, and simulated responses cannot satisfy that final acceptance. Do not change isolation, flags, or authentication to make a demo pass.

## Verification record

See [local demo verification](local-demo-verification.md) for the exact checks and remaining blocks.
