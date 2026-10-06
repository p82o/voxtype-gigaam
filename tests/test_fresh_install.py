"""Exercise a fresh installation with isolated paths and external tools mocked."""
import hashlib
import json
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

REPO = Path(__file__).resolve().parents[1]
IMAGE = "sha256:" + "1" * 64

# Mock only external Docker/systemd/download operations; the model preparation,
# checksum checks, audit policy and config merger run from the repository.
TOOL = r'''
import json, os, subprocess, sys
from pathlib import Path
root = Path(os.environ["FRESH_TEST_ROOT"])
args = sys.argv[1:]
name = Path(sys.argv[0]).name
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name, args]) + "\n")
if name == "curl":
    url = next(a for a in args if a.startswith("https://"))
    filename = "gigaam.tar.gz" if "api.github.com" in url else url.rsplit("/", 1)[1]
    data = (root / "downloads" / filename).read_bytes()
    if os.environ.get("CORRUPT_DOWNLOAD"): data = b"corrupt"
    Path(args[args.index("-o") + 1]).write_bytes(data)
elif name == "docker":
    image = "sha256:" + "1" * 64
    if args[0] == "inspect": sys.exit(1)
    if args[:2] == ["image", "inspect"]: print(image)
    elif args[:2] == ["image", "save"]:
        Path(args[args.index("--output") + 1]).write_bytes(b"image archive")
    elif args[0] == "run":
        mounts = {}
        for i, arg in enumerate(args):
            if arg == "--mount":
                parts = dict(p.split("=", 1) for p in args[i+1].split(",") if "=" in p)
                mounts[parts["dst"]] = parts["src"]
        def mapped(value):
            for destination, source in mounts.items():
                if value == destination or value.startswith(destination + "/"):
                    return source + value[len(destination):]
            return value
        if "pip-audit" in args:
            if os.environ.get("AUDIT_FAIL"): sys.exit(2)
            frozen = Path(mapped(args[args.index("-r") + 1])).read_text()
            packages = [dict(zip(("name", "version"), line.split("==")), vulns=[]) for line in frozen.splitlines()]
            Path(mapped(args[args.index("-o") + 1])).write_text(json.dumps({"dependencies": packages}))
        elif any(arg.startswith("aquasec/trivy:") for arg in args):
            Path(mapped(args[args.index("--output") + 1])).write_text(json.dumps({"Results": [{"Type": "debian"}]}))
        elif "python" in args:
            command = args[args.index("python") + 1:]
            if command[0] == "-":
                result = subprocess.run([sys.executable, "-", *[mapped(a) for a in command[1:]]], input=sys.stdin.buffer.read(), capture_output=True)
                sys.stdout.buffer.write(result.stdout)
                sys.exit(result.returncode)
            elif command[0] != "-c":
                sys.exit(subprocess.run([sys.executable, *[mapped(a) for a in command]]).returncode)
elif name in ("systemctl", "voxtype"):
    pass
'''


class FreshInstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.checkout = self.root / "repo"
        self.checkout.mkdir()
        self.home = self.root / "target-user"
        self.config = self.home / ".config/voxtype/config.toml"
        self.config.parent.mkdir(parents=True)
        self.hotkey = b'[hotkey]\r\nkey = "EVTEST_582"\r\n# custom key\r\n'
        self.config.write_bytes(self.hotkey)
        # Redirect HOME-derived paths in the test copy, without changing HOME or
        # adding test-only installation options to the production script.
        source = (REPO / "install.sh").read_text().replace("$HOME", "$FRESH_INSTALL_HOME")
        (self.checkout / "install.sh").write_text(source)
        shutil.copytree(REPO / "scripts", self.checkout / "scripts")
        shutil.copytree(REPO / "systemd", self.checkout / "systemd")
        shutil.copy(REPO / "compose.yaml", self.checkout)
        (self.checkout / "security").mkdir()
        (self.checkout / "security/exceptions.json").write_text("[]")
        for lock in ("requirements", "build-requirements", "audit-requirements"):
            (self.checkout / (lock + ".lock")).write_text("test-package==1.0\n")
        model = self.checkout / "model"
        model.mkdir()
        (model / "revision.txt").write_text("1" * 40 + "\n")
        downloads = self.root / "downloads"
        downloads.mkdir()
        for filename in ("gigaam.tar.gz", "v3_e2e_rnnt.ckpt", "v3_e2e_rnnt_tokenizer.model"):
            data = ("fixture:" + filename).encode()
            (downloads / filename).write_bytes(data)
            sums = "source.SHA256SUMS" if filename == "gigaam.tar.gz" else "SHA256SUMS"
            with (model / sums).open("a") as stream:
                stream.write(hashlib.sha256(data).hexdigest() + "  " + filename + "\n")
        binaries = self.root / "bin"
        binaries.mkdir()
        for name in ("docker", "systemctl", "voxtype", "curl"):
            path = binaries / name
            path.write_text("#!" + sys.executable + "\n" + TOOL)
            path.chmod(0o755)
        self.env = dict(PATH=str(binaries) + os.pathsep + os.defpath,
                        FRESH_TEST_ROOT=str(self.root), FRESH_INSTALL_HOME=str(self.home))

    def install(self, **flags):
        result = subprocess.run(["bash", str(self.checkout / "install.sh")],
                                env={**self.env, **flags}, capture_output=True, timeout=30)
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        return result.returncode, calls

    def test_fresh_install_creates_stack_units_and_preserves_hotkey(self):
        self.assertFalse((self.home / ".local/share/gigaam").exists())
        code, calls = self.install()
        self.assertEqual(code, 0)
        stack = self.home / ".local/share/gigaam/docker"
        self.assertEqual((stack / "image.env").read_text(), "GIGAAM_IMAGE=" + IMAGE + "\n")
        self.assertEqual((stack / "hotkey.sha256").read_text().strip(), hashlib.sha256(self.hotkey).hexdigest())
        self.assertTrue(self.config.read_bytes().endswith(self.hotkey))
        self.assertEqual(tomllib.loads(self.config.read_text())["whisper"]["remote_endpoint"], "http://127.0.0.1:8394")
        for unit in ("gigaam-watchdog.service", "gigaam-watchdog.timer"):
            self.assertEqual((self.home / ".config/systemd/user" / unit).read_bytes(), (REPO / "systemd" / unit).read_bytes())
        self.assertTrue(os.access(self.home / ".local/bin/gigaam-watchdog.sh", os.X_OK))
        self.assertFalse((stack / "backups").exists())
        self.assertEqual(sum(name == "curl" for name, _ in calls), 3)
        self.assertIn(["systemctl", ["--user", "enable", "--now", "gigaam-watchdog.timer"]], calls)
        self.assertIn(["systemctl", ["--user", "restart", "voxtype"]], calls)
        self.assertFalse(any("gigaam-server.service" in args for _, args in calls))
        self.assertEqual(self.install()[0], 0)
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(sum(name == "curl" for name, _ in calls), 3)

    def test_failed_audit_does_not_create_runtime_or_change_config(self):
        code, calls = self.install(AUDIT_FAIL="1")
        self.assertNotEqual(code, 0)
        self.assertEqual(self.config.read_bytes(), self.hotkey)
        self.assertFalse((self.home / ".local/share/gigaam").exists())
        self.assertFalse(any(name == "systemctl" and "stop" in args for name, args in calls))

    def test_corrupt_first_download_blocks_build_and_install(self):
        code, calls = self.install(CORRUPT_DOWNLOAD="1")
        self.assertNotEqual(code, 0)
        self.assertFalse(any(name == "docker" and args[0] == "build" for name, args in calls))
        self.assertFalse((self.home / ".local/share/gigaam").exists())
        self.assertEqual(self.config.read_bytes(), self.hotkey)
