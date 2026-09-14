#!/usr/bin/env python3
"""Validate local Compose without a daemon, downloads, or real environment files."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
env = {
    key: os.environ[key]
    for key in ("PATH", "HOME", "DOCKER_CONFIG")
    if key in os.environ
}
env.update(
    JWT_SECRET="test-only-jwt",
    DISCORD_CLIENT_ID="test-only-client",
    DISCORD_SECRET="test-only-discord",
)
command = [
    "docker", "compose", "--env-file", "/dev/null", "-f", str(ROOT / "compose.yml"),
]
config = json.loads(subprocess.check_output(
    command + ["config", "--format", "json"], env=env,
))
services = config["services"]
assert set(services) == {"frontend", "server", "ramiel"}
assert services["server"]["depends_on"]["ramiel"]["condition"] == "service_healthy"
assert services["frontend"]["depends_on"]["server"]["condition"] == "service_healthy"
for name, expected_port in (("frontend", 3000), ("server", 8081)):
    ports = services[name].get("ports", [])
    assert ports, f"{name} must publish its host port"
    assert len(ports) == 1
    assert ports[0]["host_ip"] == "127.0.0.1"
    assert int(ports[0]["target"]) == expected_port
    assert int(ports[0]["published"]) == expected_port
    assert ports[0]["protocol"] == "tcp"
for service in services.values():
    assert not service.get("platform"), "Local services must use the native Docker architecture"
    assert not service.get("profiles"), "The complete stack must start by default"
    assert service.get("healthcheck")
    assert service["build"]["provenance"] in (False, "false")
    assert service["cap_drop"] == ["ALL"]
    assert "no-new-privileges:true" in service["security_opt"]
    assert not service.get("env_file")
    assert not service.get("privileged", False)
server = services["server"]
assert server["environment"]["DATABASE_URL"] == "sqlite:///var/lib/acm/db.sqlite?mode=rwc"
assert server["volumes"][0]["type"] == "volume"
assert server["volumes"][0]["target"] == "/var/lib/acm"
assert services["frontend"]["environment"]["NEXT_PUBLIC_API_URL"] == "http://127.0.0.1:8081"
assert "JWT_SECRET" not in services["frontend"]["environment"]
ramiel = services["ramiel"]
assert set(ramiel["networks"]) == {"runner"}
assert ramiel["read_only"] is True
assert not ramiel.get("ports")
assert not ramiel.get("volumes")
assert ramiel["init"] is True
assert ramiel["pids_limit"] == 256
assert int(ramiel["mem_limit"]) == 2 * 1024**3
assert float(ramiel["cpus"]) == 2
assert len(ramiel["tmpfs"]) == 1
mount, options = ramiel["tmpfs"][0].split(":", 1)
assert mount == "/tmp"
assert set(options.split(",")) == {"rw", "exec", "nosuid", "nodev", "size=512m", "mode=1777"}
assert config["networks"]["runner"]["internal"] is True
for name in ("JWT_SECRET", "DISCORD_CLIENT_ID", "DISCORD_SECRET"):
    for value in (None, ""):
        invalid = dict(env)
        if value is None:
            invalid.pop(name)
        else:
            invalid[name] = value
        result = subprocess.run(command + ["config", "--quiet"], env=invalid, capture_output=True)
        assert result.returncode != 0, f"Missing or empty {name} must fail validation"
print("PASS: local Compose configuration, isolation, and required secrets")
