#!/usr/bin/env python3
"""Smoke-test the local stack. Pass Compose options such as --env-file PATH.

Run only against an idle local/test stack: this rebuilds services and restarts
its API. Concurrent database writes can fail the checksum check.
Uses no login tokens. Leaves services and a small persistence marker in place.
"""
import json
import subprocess
import sys
import uuid

compose = ["docker", "compose", *sys.argv[1:]]


def run(*args):
    return subprocess.check_output([*compose, *args], text=True, timeout=1800)


run("up", "--detach", "--build", "--wait", "--wait-timeout", "300")
run("exec", "-T", "server", "curl", "--fail", "--silent", "--max-time", "10",
    "http://127.0.0.1:8081/healthz")
run("exec", "-T", "frontend", "node", "-e",
    "fetch('http://127.0.0.1:3000/problems', {signal: AbortSignal.timeout(120000)})"
    ".then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))")

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
    before = run("run", "--no-deps", "--rm", "--entrypoint", "sha256sum", "server",
                 "/var/lib/acm/db.sqlite").strip()
    run("up", "--detach", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "120", "server")
    assert run("exec", "-T", "server", "cat", marker) == "retained"
    run("stop", "server")
    after = run("run", "--no-deps", "--rm", "--entrypoint", "sha256sum", "server",
                "/var/lib/acm/db.sqlite").strip()
    assert before == after, "Database changed across an idle container recreation"
finally:
    run("up", "--detach", "--no-build", "--wait", "--wait-timeout", "120", "server")
print("PASS: complete Compose startup, frontend/API health, private runner execution, and database persistence")
print("Real Discord login and browser Run/Submit were not tested by this script.")
