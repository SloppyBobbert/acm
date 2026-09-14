#!/usr/bin/env python3
"""Smoke-test the local stack. Pass Compose options such as --env-file PATH.

Run only against an idle local/test stack: this rebuilds services and restarts
its API. Concurrent database writes can fail the logical-data comparison.
Uses no login tokens. Leaves services and a small persistence marker in place.
"""
import json
import subprocess
import sys
import urllib.request
import uuid

compose = ["docker", "compose", *sys.argv[1:]]


def run(*args):
    return subprocess.check_output([*compose, *args], text=True, timeout=1800)


def database_snapshot():
    # Reuse Node's built-in SQLite, not an added package or a raw file checksum.
    # The stopped API's whole volume includes any WAL files. Mount it read-only.
    server_id = run("ps", "--all", "--quiet", "server").strip()
    image = run("images", "--quiet", "frontend").strip()
    script = """
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('/var/lib/acm/db.sqlite', {readOnly: true});
const migrations = db.prepare(
  'SELECT version, success, hex(checksum) AS checksum FROM _sqlx_migrations ORDER BY version'
).all();
if (!migrations.length) throw new Error('Expected an initialized database');
const counts = ['users', 'problems', 'tests', 'submissions'].map(
  table => db.prepare('SELECT count(*) AS n FROM "' + table + '"').get().n
);
console.log(JSON.stringify({migrations, counts}));
db.close();
"""
    output = subprocess.check_output([
        "docker", "run", "--rm", "--pull=never", "--network", "none", "--read-only",
        "--user", "10001:10001", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
        "--volumes-from", f"{server_id}:ro", "--entrypoint", "node", image,
        "--no-warnings", "-e", script,
    ], text=True, timeout=60)
    try:
        return json.loads(output)
    except ValueError as error:
        raise AssertionError("SQLite helper did not return JSON") from error


run("up", "--detach", "--build", "--wait", "--wait-timeout", "300")
for service in ("frontend", "server", "ramiel"):
    uid = run("exec", "-T", service, "id", "-u").strip()
    assert uid.isascii() and uid.isdecimal() and uid.strip("0"), f"{service}: expected a non-root UID"
# These requests originate on the host, so incorrect published ports fail the test.
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for url in ("http://127.0.0.1:8081/healthz", "http://127.0.0.1:3000/problems"):
    with opener.open(url, timeout=120) as response:
        assert response.status == 200, url

# This tests the private API-container-to-runner network, not Discord login.
body = {
    "problem_id": 123456, "user_id": 123456, "language": "rust",
    "implementation": "fn add(a: i32, b: i32) -> i32 { a + b }",
    "runtime_multiplier": None,
    "tests": [{
        "id": 0, "index": 0, "max_fuel": None,
        "input": {"name": "add", "arguments": [
            {"Int": {"Single": 2}}, {"Int": {"Single": 3}},
        ], "return_type": {"Int": "Single"}},
        "expected_output": {"Int": {"Single": 5}},
    }],
}
result = subprocess.run([
    *compose, "exec", "-T", "server", "sh", "-c",
    'exec curl --fail --silent --show-error --max-time 370 '
    '--header "Content-Type: application/json" --data-binary @- "${RAMIEL_URL:?}/run/rust"',
], input=json.dumps(body), text=True, capture_output=True, check=True, timeout=380)
try:
    response = json.loads(result.stdout)
except ValueError as error:
    raise AssertionError("Runner did not return JSON") from error
assert response.get("Ok", {}).get("passed"), response

# Test real volume retention, not just a newly created database with the same schema.
marker = "/var/lib/acm/compose-smoke-" + uuid.uuid4().hex
run("exec", "-T", "server", "sh", "-c", 'set -C; printf retained > "$1"', "sh", marker)
try:
    run("stop", "server")
    before = database_snapshot()
    run("up", "--detach", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "120", "server")
    assert run("exec", "-T", "server", "cat", marker) == "retained"
    run("stop", "server")
    after = database_snapshot()
    assert before == after, "Logical database contents changed across an idle container recreation"
finally:
    run("up", "--detach", "--no-build", "--wait", "--wait-timeout", "120", "server")
print("PASS: complete Compose startup, frontend/API health, private runner execution, and database persistence")
print("Real Discord login and browser Run/Submit were not tested by this script.")
