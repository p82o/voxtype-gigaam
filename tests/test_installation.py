"""Host-side tests for config preservation and watchdog recovery decisions."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

REPO = Path(__file__).resolve().parents[1]


class ConfigTests(unittest.TestCase):
    def merge(self, content):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_bytes(content)
            result = subprocess.run(
                [sys.executable, str(REPO / "scripts/merge-config.py"), str(path)],
                capture_output=True,
            )
            return result.returncode, path.read_bytes()

    def test_preserves_hotkey_and_unrelated_settings(self):
        hotkey = b'[hotkey]\nkey = "EVTEST_582"\nmode = "push_to_talk"\n# user comment\n\n'
        content = b'engine = "whisper"\n' + hotkey + b'[whisper]\nmode = "local"\ncustom = true\n[audio]\ndevice = "default"\n'
        code, merged = self.merge(content)
        self.assertEqual(code, 0)
        self.assertIn(hotkey, merged)
        self.assertIn(b'custom = true', merged)
        self.assertIn(b'device = "default"', merged)
        self.assertIn(b'mode = "remote"', merged)
        self.assertEqual(self.merge(merged), (0, merged))

    def test_preserves_hotkey_at_eof_without_newline(self):
        content = b'[hotkey]\nkey = "F9"'
        code, merged = self.merge(content)
        self.assertEqual(code, 0)
        self.assertTrue(merged.endswith(content))

    def test_preserves_crlf_hotkey(self):
        content = b'[hotkey]\r\nkey = "F9"\r\n\r\n[whisper]\r\nmode = "local"\r\n'
        code, merged = self.merge(content)
        self.assertEqual(code, 0)
        self.assertIn(b'[hotkey]\r\nkey = "F9"\r\n\r\n', merged)

    def test_rejects_missing_hotkey_and_invalid_toml_without_writing(self):
        for content in (b'[whisper]\nmode="local"\n', b'[hotkey]\nkey=\n'):
            code, merged = self.merge(content)
            self.assertNotEqual(code, 0)
            self.assertEqual(content, merged)

    def test_fingerprint_is_from_original_hotkey_bytes(self):
        hotkey = b'[hotkey]\r\nkey = "EVTEST_582"\r\n# user comment\r\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_bytes(hotkey)
            result = subprocess.run([sys.executable, str(REPO / "scripts/merge-config.py"), str(path)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.decode().strip(), hashlib.sha256(hotkey).hexdigest())
            self.assertTrue(path.read_bytes().endswith(hotkey))

    def test_reference_config_matches_installed_settings(self):
        example = tomllib.loads((REPO / "config/voxtype-config.toml").read_text())
        self.assertNotIn("hotkey", example)
        self.assertNotIn("device", example["audio"])
        code, merged = self.merge(b'[hotkey]\nkey="EVTEST_582"\n')
        self.assertEqual(code, 0)
        actual = tomllib.loads(merged.decode())
        self.assertEqual(actual["engine"], example["engine"])
        for section in ("whisper", "audio"):
            self.assertEqual(actual[section], example[section])


MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["MOCK_DIR"])
p = root / "state.json"
s = json.loads(p.read_text())
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([tool, args])+"\n")
code = 0
if tool == "docker":
    if args[0] == "info": code = 1 if s.get("unavailable") else 0
    elif args[0] == "inspect":
        code = 1 if s.get("missing") else 0
        if not code:
            count = s.get("inspects", 0)
            s["inspects"] = count + 1
            pid = 43 if s.get("changed") and count else 42
            print(s.get("owner", "voxtype-gigaam"), "asr", s.get("status", "running"), s.get("started", "2020-01-01T00:00:00Z"), pid)
    elif "compose" in args:
        s["recovered"] = True
        code = 1 if s.get("recovery_fails") else 0
elif tool == "curl":
    code = 0 if s.get("healthy") or s.get("recovered") else 1
elif tool == "sleep": pass
elif tool == "logger": pass
p.write_text(json.dumps(s))
sys.exit(code)
'''


class WatchdogTests(unittest.TestCase):
    def watchdog(self, **state):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "state.json").write_text(json.dumps(state))
            for name in ("docker", "curl", "sleep", "logger"):
                script = root / name
                script.write_text(MOCK)
                script.chmod(0o755)
            env = dict(os.environ, MOCK_DIR=directory, GIGAAM_STACK_DIR=directory)
            env["PATH"] = directory + os.pathsep + env["PATH"]
            result = subprocess.run(["bash", str(REPO / "scripts/gigaam-watchdog.sh")], env=env, capture_output=True, timeout=10)
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            actions = [args for name, args in calls if name == "docker" and "compose" in args]
            return result.returncode, actions, calls

    def test_healthy_restarting_and_startup_are_not_restarted(self):
        import datetime
        for state in ({"healthy": True}, {"status": "restarting"}, {"started": datetime.datetime.now(datetime.timezone.utc).isoformat()}):
            code, actions, _ = self.watchdog(**state)
            self.assertEqual((code, actions), (0, []))

    def test_stopped_and_missing_containers_are_started_without_downloads(self):
        for state in ({"status": "exited"}, {"status": "created"}, {"missing": True}):
            code, actions, _ = self.watchdog(**state)
            self.assertEqual(code, 0)
            self.assertEqual(len(actions), 1)
            self.assertIn("up", actions[0])
            self.assertIn("--no-build", actions[0])
            self.assertIn("never", actions[0])

    def test_hang_gets_two_probes_then_restart(self):
        code, actions, calls = self.watchdog()
        self.assertEqual(code, 0)
        self.assertIn("restart", actions[0])
        before = calls[:next(i for i, (name, args) in enumerate(calls) if name == "docker" and "compose" in args)]
        self.assertEqual(sum(name == "curl" for name, _ in before), 2)
        self.assertIn(["sleep", ["5"]], before)

    def test_docker_restart_between_probes_is_not_interrupted(self):
        self.assertEqual(self.watchdog(changed=True)[:2], (0, []))

    def test_unavailable_docker_and_foreign_container_are_not_modified(self):
        for state in ({"unavailable": True}, {"owner": "another-app"}):
            code, actions, _ = self.watchdog(**state)
            self.assertNotEqual(code, 0)
            self.assertEqual(actions, [])

    def test_failed_recovery_is_reported(self):
        self.assertNotEqual(self.watchdog(missing=True, recovery_fails=True)[0], 0)


if __name__ == "__main__":
    unittest.main()
