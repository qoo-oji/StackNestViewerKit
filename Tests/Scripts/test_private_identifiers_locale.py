"""check-private-identifiers.sh must fail closed: invalid UTF-8 in a patch and a failing awk/grep must stop the push
instead of reading as "no match"."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
TRAILER = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
CANARY = "zzcanaryzz"
ZERO = "0" * 40


class PrivateIdentifiersLocale(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-identifiers-")
        self.root = Path(self.directory.name)
        self.repo = self.root / "work"
        (self.repo / "Scripts").mkdir(parents=True)
        shutil.copy2(SCRIPTS / "check-private-identifiers.sh", self.repo / "Scripts" / "check-private-identifiers.sh")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "shelfsmith")
        self.git("config", "user.email", "290546180+shelfsmith@users.noreply.github.com")
        self.identifiers = self.root / "identifiers.txt"
        self.identifiers.write_text(CANARY + "\n")
        self.base = self.commit("Initial", b"clean\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def commit(self, subject, content):
        (self.repo / "file.txt").write_bytes(content)
        self.git("add", "file.txt")
        self.git("commit", "-q", "-m", subject, "-m", TRAILER)
        return self.git("rev-parse", "HEAD").stdout.decode().strip()

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def push_check(self, tip, env_extra=None, locale="en_US.UTF-8"):
        env = dict(os.environ, STACKNEST_PRIVATE_IDENTIFIERS_FILE=str(self.identifiers), LC_ALL=locale)
        env.update(env_extra or {})
        line = f"refs/heads/main {tip} refs/heads/main {self.base}\n"
        return subprocess.run([str(self.repo / "Scripts" / "check-private-identifiers.sh"), "pre-push"],
                              cwd=self.repo, input=line, capture_output=True, text=True, errors="replace", env=env)

    def leak_then_remove(self, before):
        """One commit adds `before` and then the identifier; the next removes the identifier, so only the
        patch of the first commit still shows it (the tree, names and messages are clean)."""
        self.commit("Add", before + CANARY.encode() + b"\n")
        return self.commit("Remove", before)

    def test_clean_patch_passes(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        result = self.push_check(tip)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_identifier_without_odd_bytes_stops(self):
        tip = self.leak_then_remove(b"plain\n")
        result = self.push_check(tip)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("added by an outgoing commit", result.stderr)

    def test_identifier_after_invalid_utf8_line_stops(self):
        tip = self.leak_then_remove(b"before \xff\xfe after\n")
        for locale in ["en_US.UTF-8", "ja_JP.UTF-8", "C"]:
            with self.subTest(locale=locale):
                result = self.push_check(tip, locale=locale)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("added by an outgoing commit", result.stderr)

    def test_identifier_after_invalid_utf8_in_the_same_line_stops(self):
        tip = self.leak_then_remove(b"\xff\xfe\n")
        self.assertEqual(self.push_check(tip).returncode, 1)

    def test_failing_awk_stops(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        self.stub("awk", "exit 2\n")
        result = self.push_check(tip, {"PATH": f"{self.bin}:{os.environ['PATH']}"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("awk failed", result.stderr)

    def test_failing_grep_stops(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        real = shutil.which("grep")
        # Fail only the identifier searches (they use -i); the list preparation must still work.
        self.stub("grep", f'for a in "$@"; do [ "$a" = "-i" ] && exit 2; done\nexec {real} "$@"\n')
        result = self.push_check(tip, {"PATH": f"{self.bin}:{os.environ['PATH']}"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("grep failed", result.stderr)

    def test_awk_and_grep_run_in_the_c_locale(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        log = self.root / "locales.log"
        for name in ("awk", "grep"):
            real = shutil.which(name)
            self.stub(name, f'echo "{name}=$LC_ALL" >> "{log}"\nexec {real} "$@"\n')
        result = self.push_check(tip, {"PATH": f"{self.bin}:{os.environ['PATH']}"})
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = set(log.read_text().split())
        self.assertIn("awk=C", seen)
        self.assertIn("grep=C", seen)
        self.assertEqual({entry for entry in seen if not entry.endswith("=C")}, set())


class InternalMarkersLocale(unittest.TestCase):
    """Same hole in check-internal-markers.sh (it also reads patches through awk)."""

    MARKER = "G" + "99"

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-markers-locale-")
        self.root = Path(self.directory.name)
        self.repo = self.root / "work"
        (self.repo / "Scripts").mkdir(parents=True)
        for name in ["check-internal-markers.sh", "internal-markers.txt"]:
            shutil.copy2(SCRIPTS / name, self.repo / "Scripts" / name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "shelfsmith")
        self.git("config", "user.email", "290546180+shelfsmith@users.noreply.github.com")
        self.base = self.commit("Initial", b"clean\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def commit(self, subject, content):
        (self.repo / "file.txt").write_bytes(content)
        self.git("add", "file.txt")
        self.git("commit", "-q", "-m", subject, "-m", TRAILER)
        return self.git("rev-parse", "HEAD").stdout.decode().strip()

    def check(self, env_extra=None):
        env = dict(os.environ, LC_ALL="en_US.UTF-8")
        env.update(env_extra or {})
        return subprocess.run([str(self.repo / "Scripts" / "check-internal-markers.sh"), "range", f"{self.base}..HEAD"],
                              cwd=self.repo, capture_output=True, text=True, errors="replace", env=env)

    def leak_then_remove(self, before):
        self.commit("Add", before + self.MARKER.encode() + b"\n")
        self.commit("Remove", before)

    def test_clean_passes(self):
        self.commit("Clean", b"clean\nmore\n")
        self.assertEqual(self.check().returncode, 0)

    def test_marker_without_odd_bytes_stops(self):
        self.leak_then_remove(b"plain\n")
        self.assertEqual(self.check().returncode, 1)

    def test_marker_after_invalid_utf8_line_stops(self):
        self.leak_then_remove(b"before \xff\xfe after\n")
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_failing_awk_stops(self):
        self.commit("Clean", b"clean\nmore\n")
        stub = self.bin / "awk"
        stub.write_text("#!/bin/sh\nexit 2\n")
        stub.chmod(0o755)
        result = self.check({"PATH": f"{self.bin}:{os.environ['PATH']}"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("awk failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
