"""番人の補強の試験: grep の失敗で止めること・push 先の remote だけを見ること・gh の投稿の文面・注釈付きタグ・
`Claude-Session :`。"""

from pathlib import Path
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
SESSION_URL = "https://claude.ai/code/" + "session_example"
PHASE = "G" + "99"
TRAILER = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"


def git(cwd, *args, check=True, env=None):
    return subprocess.run(["git", *args], cwd=cwd, check=check, capture_output=True, text=True, env=env)


class Base(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-hardening-")
        self.root = Path(self.directory.name)
        self.repo = self.root / "work"
        (self.repo / "Scripts" / "githooks").mkdir(parents=True)
        for path in SCRIPTS.rglob("*"):
            if path.is_file():
                shutil.copy2(path, self.repo / "Scripts" / path.relative_to(SCRIPTS))
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "shelfsmith")
        self.git("config", "user.email", "290546180+shelfsmith@users.noreply.github.com")
        self.identifiers = self.root / "identifiers.txt"
        self.identifiers.write_text("zzcanaryzz\n")
        self.env = dict(os.environ, STACKNEST_PRIVATE_IDENTIFIERS_FILE=str(self.identifiers))
        self.commit("Initial", TRAILER)

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args, check=True):
        return git(self.repo, *args, check=check)

    def commit(self, subject, body):
        (self.repo / "file.txt").write_text(subject)
        self.git("add", "file.txt")
        self.git("commit", "-q", "-m", subject, "-m", body)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def script(self, name, *args, stdin=""):
        return subprocess.run([str(self.repo / "Scripts" / name), *args], cwd=self.repo, input=stdin,
                              capture_output=True, text=True, env=self.env)


class FailClosedTests(Base):
    def test_internal_markers_range_and_text_fail_on_an_invalid_vocabulary(self):
        with open(self.repo / "Scripts" / "internal-markers.txt", "a") as handle:
            handle.write("foo(\n")
        self.commit("Second", f"mentions {PHASE}")
        result = self.script("check-internal-markers.sh", "range", "main~1..main")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("internal-markers: grep failed", result.stderr)
        self.assertEqual(self.script("check-internal-markers.sh", "text", stdin="nothing\n").returncode, 1)

    def test_private_identifiers_fail_on_an_invalid_list(self):
        self.identifiers.write_text("foo(\n")
        base = self.git("rev-parse", "HEAD").stdout.strip()
        tip = self.commit("Second", TRAILER)
        result = self.script("check-private-identifiers.sh", "pre-push",
                             stdin=f"refs/heads/main {tip} refs/heads/main {base}\n")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.script("check-private-identifiers.sh", "text", stdin="nothing\n").returncode, 1)


class PushTargetTests(Base):
    def setUp(self):
        super().setUp()
        for name in ["origin", "mirror"]:
            git(self.root, "init", "-q", "--bare", str(self.root / f"{name}.git"))
            self.git("remote", "add", name, str(self.root / f"{name}.git"))
        self.bad = self.commit("Second", f"mentions {PHASE}\nClaude-Session: {SESSION_URL}")
        # the bad commit already sits on the other remote (pushed without any hook), so its tracking ref exists
        self.git("push", "-q", "mirror", "main:topic")
        self.git("fetch", "-q", "mirror")
        self.line = f"refs/heads/fresh {self.bad} refs/heads/fresh {'0' * 40}\n"

    def test_without_a_remote_name_any_remote_hides_the_commit(self):
        self.assertEqual(self.script("check-commit-trailers.sh", "pre-push", stdin=self.line).returncode, 0)

    def test_new_ref_is_checked_against_the_push_target_only(self):
        for name in ["check-commit-trailers.sh", "check-internal-markers.sh", "check-private-identifiers.sh"]:
            if name == "check-private-identifiers.sh":
                self.identifiers.write_text(PHASE + "\n")
            result = self.script(name, "pre-push", "origin", stdin=self.line)
            self.assertEqual(result.returncode, 1, f"{name}: {result.stderr}")

    def test_new_ref_already_on_the_push_target_is_not_rechecked(self):
        line = f"refs/heads/fresh {self.bad} refs/heads/fresh {'0' * 40}\n"
        self.assertEqual(self.script("check-commit-trailers.sh", "pre-push", "mirror", stdin=line).returncode, 0)

    def test_push_to_a_bare_url_checks_the_whole_history(self):
        result = self.script("check-commit-trailers.sh", "pre-push", str(self.root / "elsewhere.git"), stdin=self.line)
        self.assertEqual(result.returncode, 1)


class FakeGh:
    def __init__(self, test):
        self.bin = test.root / "bin"
        self.bin.mkdir()
        self.log = test.root / "gh.log"
        gh = self.bin / "gh"
        gh.write_text('#!/bin/sh\nif [ "$1" = api ]; then echo shelfsmith; exit 0; fi\n'
                      f'echo "$@" >> "{self.log}"\n')
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        test.env["PATH"] = f"{self.bin}:{test.env['PATH']}"

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""


class GhGuardedTests(Base):
    def setUp(self):
        super().setUp()
        self.gh = FakeGh(self)

    def post(self, *args):
        return self.script("gh-guarded.sh", *args)

    def test_clean_body_reaches_gh(self):
        result = self.post("issue", "create", "--title", "T", "--body", "plain words")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("issue create", self.gh.calls())

    def test_session_url_is_refused(self):
        result = self.post("pr", "create", "--title", "T", "--body", f"Generated with {SESSION_URL}")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.gh.calls(), "")

    def test_session_trailer_line_is_refused(self):
        result = self.post("pr", "create", "--title", "T", "--body", f"text\nClaude-Session: {SESSION_URL}")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.gh.calls(), "")

    def test_internal_marker_is_refused(self):
        result = self.post("issue", "comment", "1", "--body", f"fixed in {PHASE}")
        self.assertEqual(result.returncode, 1)
        self.assertIn("internal-markers", result.stderr)
        self.assertEqual(self.gh.calls(), "")

    def test_marker_in_a_body_file_is_refused_but_its_path_is_not_a_marker(self):
        folder = self.root / "Users"
        folder.mkdir()
        body = folder / "body.txt"
        body.write_text("plain words\n")
        self.assertEqual(self.post("issue", "create", "--title", "T", "--body-file", str(body)).returncode, 0)
        body.write_text(f"see {PHASE}\n")
        self.assertEqual(self.post("issue", "create", "--title", "T", "--body-file", str(body)).returncode, 1)


class TagAndTrailerTests(Base):
    def setUp(self):
        super().setUp()
        FakeGh(self)

    def run_hook(self, stdin):
        return subprocess.run([str(self.repo / "Scripts" / "githooks" / "pre-push"), "origin", "x"], cwd=self.repo,
                              input=stdin, capture_output=True, text=True, env=self.env)

    def tag_line(self, name, message):
        self.git("tag", "-a", name, "-m", message)
        sha = self.git("rev-parse", name).stdout.strip()
        return f"refs/tags/{name} {sha} refs/tags/{name} {'0' * 40}\n"

    def test_annotated_tag_with_session_line_is_refused(self):
        result = self.run_hook(self.tag_line("v1", f"Release\n\nClaude-Session: {SESSION_URL}"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refs/tags/v1 refused", result.stderr)

    def test_annotated_tag_with_internal_marker_is_refused(self):
        result = self.run_hook(self.tag_line("v2", f"Release for {PHASE}"))
        self.assertNotEqual(result.returncode, 0)

    def test_annotated_tag_with_identifier_is_refused(self):
        result = self.run_hook(self.tag_line("v3", "Release zzcanaryzz"))
        self.assertNotEqual(result.returncode, 0)

    def test_clean_annotated_tag_and_lightweight_tag_pass(self):
        self.assertEqual(self.run_hook(self.tag_line("v4", "Release 0.1.0")).returncode, 0)
        self.git("tag", "light")
        sha = self.git("rev-parse", "light").stdout.strip()
        self.assertEqual(self.run_hook(f"refs/tags/light {sha} refs/tags/light {'0' * 40}\n").returncode, 0)

    def test_space_before_the_colon_is_caught(self):
        self.commit("Second", "Claude-Session : abc123")
        self.assertEqual(self.script("check-commit-trailers.sh", "range", "main~1..main").returncode, 1)


if __name__ == "__main__":
    unittest.main()
