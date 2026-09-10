"""Run with python3 scripts/tests/test_dev_local.py. No real services or .env access."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = (Path(__file__).resolve().parents[1] / "dev-local.sh").read_text()


class DevLocalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="acm-dev-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root)}

    def shell(self, code, **env):
        return subprocess.run(
            ["/bin/bash", "-c", "set -euo pipefail\n" + code],
            env={**self.env, **env}, cwd="/", capture_output=True, text=True, timeout=10,
        )

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o700)

    def test_optional_homebrew(self):
        probe = SCRIPT.split('LOG_DIR="$ROOT_DIR/.local/logs"', 1)[1].split('mkdir -p "$LOG_DIR"', 1)[0]
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for case in ("absent", "failed", "available"):
            with self.subTest(case=case):
                if case == "failed":
                    self.executable(bin_dir / "brew", "exit 1\n")
                if case == "available":
                    self.executable(bin_dir / "brew", f"printf '%s\\n' '{self.root}'\n")
                    self.executable(self.root / "opt/node@18/bin/node", "exit 0\n")
                result = self.shell(probe + '\nprintf "%s" "$PATH"', PATH=str(bin_dir))
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = str(bin_dir)
                if case == "available":
                    expected = f"{self.root}/opt/node@18/bin:{expected}"
                self.assertEqual(result.stdout, expected)

    def docker_case(self, fail=False):
        # Mock the absolute compiler probe, so this test never starts a host runner.
        start = SCRIPT.split("start_ramiel() {", 1)[1].split("\n}\n\nstart_ramiel", 1)[0]
        self.assertIn("[[ -x /opt/wasi-sdk/bin/clang++ ]]", start)
        start = start.replace("[[ -x /opt/wasi-sdk/bin/clang++ ]]", "false")
        cleanup = SCRIPT.split("cleanup() {", 1)[1].split("\n}\n", 1)[0]
        sdk = self.root / "custom-sdk"
        self.executable(sdk / "bin/clang++", "exit 0\n")
        self.executable(self.root / "target/debug/ramiel", "exit 0\n")
        calls = self.root / "docker-calls"
        code = '''
ROOT_DIR="$HOME"
LOG_DIR="$HOME"
RAMIEL_HOSTNAME=127.0.0.1
RAMIEL_PORT=8082
docker() {
    printf '%s\\n' "$*" >> "$HOME/docker-calls"
    if [[ "$1" == run ]]; then
        if [[ "$FAIL_RUN" == 1 ]]; then return 1; fi
        printf '%s\\n' review-owned-container-id
    fi
}
'''
        code += "cleanup() {" + cleanup + "\n}\ntrap cleanup EXIT\n"
        code += "start_ramiel() {" + start + "\n}\nstart_ramiel\nwait\n"
        result = self.shell(code, WASI_SDK=str(sdk), FAIL_RUN=str(int(fail)))
        return result, calls.read_text().splitlines() if calls.exists() else []

    def test_docker_fallback_uses_absolute_path_and_owned_id(self):
        result, calls = self.docker_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(f"-f {self.root}/Dockerfile.ramiel" in call for call in calls), calls)
        self.assertTrue(any(call.startswith("run ") for call in calls), calls)
        self.assertFalse(any(call.startswith("rm ") for call in calls), calls)
        self.assertIn("stop review-owned-container-id", calls)
        self.assertFalse(any("acm-ramiel-local" in call for call in calls), calls)

    def test_failed_container_start_does_not_stop_another_runner(self):
        result, calls = self.docker_case(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call.startswith(("rm ", "stop ")) for call in calls), calls)

    def test_frontend_origin_is_an_environment_value_not_a_flag(self):
        self.executable(
            self.root / "target/debug/server",
            'printf "%s\\n" "${FRONTEND_ORIGIN-unset}" "$@" > "$HOME/server-call"\n',
        )
        invocation = SCRIPT.split('echo "Starting API at http://$API_HOSTNAME:$PORT"', 1)[1]
        invocation = invocation.split("server_pid=$!", 1)[0]
        code = '''
ROOT_DIR="$HOME"
LOG_DIR="$HOME"
JWT_SECRET=review-only
DISCORD_SECRET=review-only
DISCORD_CLIENT_ID=review-only
FRONTEND_ORIGIN=http://127.0.0.1:3000
DISCORD_REDIRECT_URI=$FRONTEND_ORIGIN/auth/discord
COOKIE_SECURE=false
API_HOSTNAME=127.0.0.1
PORT=8081
DATABASE_URL=sqlite://./test.sqlite
RAMIEL_URL=http://127.0.0.1:8082
'''
        result = self.shell(code + invocation + "\nwait\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / "server-call").read_text().splitlines()
        self.assertEqual(args[0], "http://127.0.0.1:3000")
        self.assertNotIn("--frontend-origin", args)
        self.assertIn("--discord-client-id", args)
        self.assertIn("--discord-redirect-uri", args)


if __name__ == "__main__":
    unittest.main()
