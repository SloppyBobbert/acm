#!/usr/bin/env python3
"""Test recovery in a new, isolated Compose project using existing local images.

No real credentials or existing databases are used. A temporary loopback port
tests bind conflicts. Services are stopped at exit; test containers, volume,
and configuration are retained.
Run test-local-compose.py first to build the images. No images are downloaded.
"""
import concurrent.futures
import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
(ROOT / ".local").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="acm-recovery-", dir=ROOT / ".local"))
project = work.name
print(f"Test project: {project}; retained configuration: {work}", flush=True)
override = work / "compose.yml"
override.write_text("services:\n  server:\n    ports: !override []\n  frontend:\n    ports: !override []\n")
env = {key: os.environ[key] for key in (
    "PATH", "HOME", "DOCKER_CONFIG", "DOCKER_HOST", "DOCKER_CONTEXT",
    "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY",
) if key in os.environ}
env.update(JWT_SECRET="recovery-test-only", DISCORD_CLIENT_ID="recovery-test-only",
           DISCORD_SECRET="recovery-test-only")
compose = ["docker", "compose", "--env-file", "/dev/null", "--project-name", project,
           "-f", str(ROOT / "compose.yml"), "-f", str(override)]


def run(*args, check=True, input=None, timeout=180):
    return subprocess.run([*compose, *args], env=env, text=True, input=input,
                          capture_output=True, check=check, timeout=timeout)


def start(service):
    run("up", "--detach", "--no-build", "--pull", "never", "--wait",
        "--wait-timeout", "120", service)


def request(form):
    return run("exec", "-T", "server", "sh", "-c",
               'exec curl --fail --silent --show-error --max-time 45 '
               '-H "Content-Type: application/json" --data-binary @- "$RAMIEL_URL/run/rust"',
               input=json.dumps(form), check=False, timeout=60)


def parse_json(value):
    try:
        return json.loads(value)
    except ValueError as error:
        raise AssertionError("Expected JSON from the test command") from error


def expect_pass(form):
    result = request(form)
    assert result.returncode == 0, result.stderr
    assert parse_json(result.stdout).get("Ok", {}).get("passed"), result.stdout


config = parse_json(run("config", "--format", "json").stdout)
volume = config["volumes"]["local_data"]
assert volume["name"] == f"{project}_local_data" and not volume.get("external")
mounts = config["services"]["server"]["volumes"]
assert len(mounts) == 1 and mounts[0]["type"] == "volume"
assert mounts[0]["source"] == "local_data" and mounts[0]["target"] == "/var/lib/acm"
assert config["services"]["server"]["environment"]["DATABASE_URL"] == "sqlite:///var/lib/acm/db.sqlite?mode=rwc"
assert all(not service.get("ports") for service in config["services"].values())
existing = subprocess.run(["docker", "volume", "inspect", volume["name"]], env=env,
                          capture_output=True, timeout=10)
assert existing.returncode != 0, "Refusing an existing volume"

form = {
    "problem_id": 1, "user_id": 1,
    "implementation": "pub fn check(value: i32) -> i32 { value + 1 }",
    "runtime_multiplier": None,
    "tests": [{"id": 0, "index": 0, "max_fuel": None,
               "input": {"name": "check", "arguments": [{"Int": {"Single": 3}}],
                         "return_type": {"Int": "Single"}},
               "expected_output": {"Int": {"Single": 4}}}],
}
try:
    start("server")
    expect_pass(form)
    run("stop", "ramiel")
    unavailable = request(form)
    assert unavailable.returncode in {6, 7, 28}, unavailable.stdout + unavailable.stderr
    run("exec", "-T", "server", "curl", "--fail", "--silent", "--max-time", "10",
        "http://127.0.0.1:8081/healthz")
    start("ramiel")
    expect_pass(form)
    print("PASS: runner outage is visible to its API-container client; restart restores compilation", flush=True)

    interrupted = copy.deepcopy(form)
    interrupted["problem_id"] = 2
    interrupted["implementation"] = "pub fn check(value: i32) -> i32 { loop { std::hint::black_box(value); } }"
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        pending = executor.submit(request, interrupted)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            assert not pending.done(), "Request finished before the interruption"
            artifact = run("exec", "-T", "ramiel", "test", "-s",
                           "/tmp/acm/rust/submissions/1/2/out.wasm", check=False)
            if artifact.returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise AssertionError("Compiler did not produce the in-flight job artifact")
        assert not pending.done(), "Request finished before the interruption"
        run("kill", "--signal", "SIGKILL", "ramiel")
        assert pending.result(timeout=15).returncode != 0, "Interrupted request reported success"
    start("ramiel")
    form["problem_id"] = 2
    expect_pass(form)
    print("PASS: in-flight request fails on runner kill; the same job prefix works after restart", flush=True)

    run("exec", "-T", "server", "sh", "-c", "printf retained > /var/lib/acm/recovery-marker")
    run("kill", "--signal", "SIGKILL", "server")
    start("server")
    assert run("exec", "-T", "server", "cat", "/var/lib/acm/recovery-marker").stdout == "retained"
    expect_pass(form)
    print("PASS: API recovers after SIGKILL and retains its test volume", flush=True)

    # Hold a real host socket; a Docker port mapping alone is not a reliable reservation.
    run("stop", "server")
    with socket.socket() as held_port:
        held_port.bind(("127.0.0.1", 0))
        held_port.listen(1)
        port = held_port.getsockname()[1]
        override.write_text(f'services:\n  server:\n    ports: !override ["127.0.0.1:{port}:8081"]\n'
                            '  frontend:\n    ports: !override []\n')
        conflict = run("up", "--detach", "--no-build", "--pull", "never", "--wait",
                       "--wait-timeout", "10", "server", check=False)
        assert conflict.returncode != 0, "An occupied port must prevent startup"
        assert any(message in conflict.stderr.lower() for message in
                   ["port is already allocated", "address already in use"]), conflict.stderr
    print("PASS: occupied loopback port prevents startup with a bind error", flush=True)
except subprocess.CalledProcessError as error:
    print(error.stderr, flush=True)
    raise
finally:
    print(f"Stopping services; retaining test project and volume: {project}", flush=True)
    stopped = run("stop", check=False)
    assert stopped.returncode == 0, stopped.stderr

print("PASS: isolated recovery checks; authenticated job submission/replay was not tested")
