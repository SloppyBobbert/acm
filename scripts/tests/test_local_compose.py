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
for name in ("frontend", "server"):
    assert not services[name].get("profiles")
    assert all(port["host_ip"] == "127.0.0.1" for port in services[name]["ports"])
for service in services.values():
    assert not service.get("platform"), "Local services must use the native Docker architecture"
    assert not service.get("profiles"), "The complete stack must start by default"
    assert service.get("healthcheck")
    assert service["build"]["provenance"] in (False, "false")
    assert service["cap_drop"] == ["ALL"]
    assert "no-new-privileges:true" in service["security_opt"]
    assert not service.get("env_file")
server = services["server"]
assert server["environment"]["DATABASE_URL"] == "sqlite:///var/lib/acm/db.sqlite?mode=rwc"
assert server["volumes"][0]["type"] == "volume"
assert server["volumes"][0]["target"] == "/var/lib/acm"
assert services["frontend"]["environment"]["NEXT_PUBLIC_API_URL"] == "http://127.0.0.1:8081"
assert "JWT_SECRET" not in services["frontend"]["environment"]
assert services["ramiel"]["read_only"] is True
assert not services["ramiel"].get("ports")
assert config["networks"]["runner"]["internal"] is True
missing = dict(env)
missing.pop("JWT_SECRET")
result = subprocess.run(command + ["config", "--quiet"], env=missing, capture_output=True)
assert result.returncode != 0, "Missing secrets must fail validation"
print("PASS: local Compose configuration, isolation, and required secrets")
