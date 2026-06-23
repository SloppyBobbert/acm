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
echo "DATABASE_URL=sqlite://./db.sqlite" > .env
touch db.sqlite
```

Build the frontend automatically on changes:

```sh
cd lilith
corepack yarn install
NEXT_PUBLIC_API_URL=http://127.0.0.1:8081 NEXT_PUBLIC_WS_URL=ws://127.0.0.1:8081/ws corepack yarn dev
```

Then run the server:

```sh
JWT_SECRET={JWT_SECRET} DISCORD_SECRET={DISCORD_SECRET} cargo run --package server
```

And finally run the build server.

```sh
cargo run --package ramiel
```

## Planned Features

- Import openly licensed Kattis/ICPC or DMOJ-style problem packages into the existing problem database. Imported packages should include reuse permission, statements, starter code, reference solutions, and hidden tests. Do not mirror LeetCode statements or tests without explicit permission.
