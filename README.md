# Chico ACM Website

This repository holds the code for the website that is currently in use by the
Chico chapter of the Association of Computing Machinery (ACM) at
[chicoacm.org](https://chicoacm.org). 

The website compiles arbitrary C++ code using
[wasi-sdk](https://github.com/WebAssembly/wasi-sdk) and runs it against
pre-defined tests. Due to the code running with WebAssembly, the site is able to
offer fully deterministic timing of solutions. The Chico ACM chapter uses the
site to both host local competitions and conduct our weekly meetings.

<p align="center">
  <img alt="Screenshot showing the problem editor view of the website." src="https://user-images.githubusercontent.com/32966690/219970015-3bc81d53-9811-4a33-901a-736dfc7047e5.png" width="45%">
  <img alt="Screenshot showing the submission view of the website." src="https://user-images.githubusercontent.com/32966690/219970017-b9efecda-0583-498f-9705-8c1ca65c3594.png" width="45%">
  <br />
  <span>The fastest solution to the <a href="https://chicoacm.org/problems/30">Poker Hand</a> problem. I spent 5 hours working on this.</span>
</p>

## Running

First install Rust, then clone the repo.

```sh
git clone git@github.com:/kil0meters/acm.git
cd acm
```

Initialize the database:

```sh
cp .env.example .env
touch db.sqlite
```

The migrations create the schema only. To add sample content for local UI
development, start the local stack and wait for the API to run migrations. Then
run the optional seed script from another terminal:

```sh
./scripts/dev-local.sh
# In another terminal, after migrations finish:
./scripts/seed-local-db.sh
```

For local frontend environment variables:

```sh
cp lilith/.env.local.example lilith/.env.local
```

To start the API, build runner, and frontend together:

```sh
./scripts/dev-local.sh
```

For manual startup, run each service in a separate terminal.

Start the build runner:

```sh
cargo run --package ramiel
```

Start the API with the values from `.env`:

```sh
set -a
source .env
set +a
cargo run --package server -- --hostname "$API_HOSTNAME"
```

Build the frontend automatically on changes:

```sh
cd lilith
corepack yarn install
set -a
source ../.env
set +a
NEXT_PUBLIC_API_URL="${NEXT_PUBLIC_API_URL:-http://${API_HOSTNAME:-127.0.0.1}:${PORT:-8081}}" \
NEXT_PUBLIC_WS_URL="${NEXT_PUBLIC_WS_URL:-ws://${API_HOSTNAME:-127.0.0.1}:${PORT:-8081}/ws}" \
corepack yarn dev
```

### Docker

The Ramiel image uses the amd64 WASI SDK package. On Apple Silicon, build and run
the local Docker images with `--platform linux/amd64`. Disable provenance for
local builds so Docker can run the tagged images with the requested platform:

```sh
docker build --provenance=false --platform linux/amd64 -f Dockerfile.server -t acm-server:local .
docker build --provenance=false --platform linux/amd64 -f Dockerfile.ramiel -t acm-ramiel:local .
docker run --pull=never --platform linux/amd64 acm-ramiel:local
```
