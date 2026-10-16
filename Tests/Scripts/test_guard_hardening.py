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
PHASE_BRANCH = "phase-" + "g63-x"
TRAILER = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"


def git(cwd, *args, check=True, env=None):
    return subprocess.run(["git", *args], cwd=cwd, check=check, capture_output=True, text=True, env=env)


class Base(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-hardening-")
        self.root = Path(self.directory.name)
        self.repo = self.root / "work"
        (self.repo / "Scripts" / "githooks").mkdir(parents=True)
        # Copy only the tracked files: an ignored __pycache__ or editor leftover must not change what is tested.
        listing = subprocess.run(["git", "ls-files", "-z", "Scripts"], cwd=SCRIPTS.parent, check=True,
                                 capture_output=True).stdout
        for name in filter(None, listing.decode("utf-8").split("\0")):
            source = SCRIPTS.parent / name
            if source.is_file():
                destination = self.repo / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
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
    """Each grep helper must fail closed on its own. The copy of a script under test keeps just one helper
    (the others are replaced by `:`), so a revert of that helper alone makes the test fail."""

    def keep_only(self, name, drop):
        path = self.repo / "Scripts" / name
        text = path.read_text()
        for line in drop:
            self.assertEqual(text.count(line), 1, line)
            text = text.replace(line, line.replace(line.strip(), ":"))
        path.write_text(text)

    def test_internal_markers_each_helper_fails_closed(self):
        with open(self.repo / "Scripts" / "internal-markers.txt", "a") as handle:
            handle.write("foo(\n")
        self.commit("Second", f"mentions {PHASE}")
        calls = ['check_messages "$@"', 'check_patches "$@"', 'check_paths "$@"']
        expected = {'check_messages "$@"': "commit messages", 'check_patches "$@"': "added lines",
                    'check_paths "$@"': "file names"}
        for keep in calls:
            with self.subTest(helper=keep):
                original = (self.repo / "Scripts" / "check-internal-markers.sh").read_text()
                self.keep_only("check-internal-markers.sh", ["    " + c for c in calls if c != keep])
                result = self.script("check-internal-markers.sh", "range", "main~1..main")
                (self.repo / "Scripts" / "check-internal-markers.sh").write_text(original)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"internal-markers: grep failed on the {expected[keep]}", result.stderr)
        self.assertEqual(self.script("check-internal-markers.sh", "text", stdin="nothing\n").returncode, 1)

    def test_private_identifiers_each_helper_fails_closed(self):
        self.identifiers.write_text("foo(\n")
        base = self.git("rev-parse", "HEAD").stdout.strip()
        tip = self.commit("Second", TRAILER)
        stdin = f"refs/heads/main {tip} refs/heads/main {base}\n"
        calls = ['check_commits "$@"', 'check_patches "$@"', 'check_paths "$@"']
        expected = {'check_commits "$@"': "commit messages", 'check_patches "$@"': "added lines",
                    'check_paths "$@"': "file names"}
        for keep in calls:
            with self.subTest(helper=keep):
                original = (self.repo / "Scripts" / "check-private-identifiers.sh").read_text()
                self.keep_only("check-private-identifiers.sh",
                               ["        " + c for c in calls if c != keep] + ['        check_tree "$local_sha"'])
                result = self.script("check-private-identifiers.sh", "pre-push", stdin=stdin)
                (self.repo / "Scripts" / "check-private-identifiers.sh").write_text(original)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"private-identifiers: grep failed on the {expected[keep]}", result.stderr)
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
                      f'echo "$@" >> "{self.log}"\ncat > "{self.log}.stdin"\n')
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        test.env["PATH"] = f"{self.bin}:{test.env['PATH']}"

    def stdin(self):
        path = Path(f"{self.log}.stdin")
        return path.read_text() if path.exists() else ""

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

    def test_bare_dash_stdin_body_is_checked(self):
        refused = self.script("gh-guarded.sh", "gist", "create", "-", stdin=f"see {PHASE}\n")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("internal marker", refused.stderr)
        self.assertEqual(self.gh.calls(), "")
        clean = self.script("gh-guarded.sh", "gist", "create", "-", stdin="plain words\n")
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertIn("gist create", self.gh.calls())
        # gh keeps its stdin semantics: it gets "-" itself and the checked body on stdin.
        self.assertEqual(self.gh.calls().split(), ["gist", "create", "-"])
        self.assertEqual(self.gh.stdin(), "plain words\n")
        named = self.script("gh-guarded.sh", "gist", "create", "-f", "notes.md", "-", stdin="more words\n")
        self.assertEqual(named.returncode, 0, named.stderr)
        self.assertTrue(self.gh.calls().strip().endswith("gist create -f notes.md -"), self.gh.calls())
        self.assertEqual(self.gh.stdin(), "more words\n")


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

    def test_unreadable_object_type_refuses_the_push(self):
        # A failing `git cat-file -t` must not read as "not a tag" (the tag message would go unchecked).
        line = self.tag_line("v5", "Release zzcanaryzz")
        real_git = shutil.which("git")
        stub = Path(self.env["PATH"].split(":")[0]) / "git"
        stub.write_text(f'#!/bin/sh\n[ "$1" = cat-file ] && [ "$2" = -t ] && exit 128\nexec {real_git} "$@"\n')
        stub.chmod(0o755)
        result = self.run_hook(line)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read the object", result.stderr)

    def test_clean_annotated_tag_and_lightweight_tag_pass(self):
        self.assertEqual(self.run_hook(self.tag_line("v4", "Release 0.1.0")).returncode, 0)
        self.git("tag", "light")
        sha = self.git("rev-parse", "light").stdout.strip()
        self.assertEqual(self.run_hook(f"refs/tags/light {sha} refs/tags/light {'0' * 40}\n").returncode, 0)

    def test_raw_tag_sha_refspec_is_checked_by_object_type(self):
        self.git("tag", "-a", "raw", "-m", f"Release\n\nClaude-Session: {SESSION_URL}")
        sha = self.git("rev-parse", "raw").stdout.strip()
        result = self.run_hook(f"{sha} {sha} refs/tags/x {'0' * 40}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refs/tags/x refused", result.stderr)

    def test_nested_tag_chain_is_checked(self):
        self.git("tag", "-a", "inner", "-m", f"Inner\n\nClaude-Session: {SESSION_URL}")
        inner = self.git("rev-parse", "inner").stdout.strip()
        self.git("tag", "-a", "outer", "-m", "clean outer", inner)
        outer = self.git("rev-parse", "outer").stdout.strip()
        self.assertEqual(self.git("cat-file", "-t", outer).stdout.strip(), "tag")
        result = self.run_hook(f"refs/tags/outer {outer} refs/tags/outer {'0' * 40}\n")
        self.assertNotEqual(result.returncode, 0)
        self.git("tag", "-a", "clean-inner", "-m", "clean")
        clean_inner = self.git("rev-parse", "clean-inner").stdout.strip()
        self.git("tag", "-a", "clean-outer", "-m", "clean outer", clean_inner)
        clean_outer = self.git("rev-parse", "clean-outer").stdout.strip()
        self.assertEqual(self.run_hook(f"refs/tags/clean-outer {clean_outer} refs/tags/clean-outer {'0' * 40}\n")
                         .returncode, 0)

    def test_ref_names_are_checked(self):
        head = self.git("rev-parse", "HEAD").stdout.strip()
        zero = "0" * 40
        for name in [f"refs/heads/{PHASE_BRANCH}", f"refs/tags/{PHASE}-light", "refs/heads/zzcanaryzz"]:
            with self.subTest(name=name):
                result = self.run_hook(f"refs/heads/main {head} {name} {zero}\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"ref name {name} refused", result.stderr)
        for name in ["refs/heads/feature/viewer-kit-0.1", "refs/tags/0.1.0"]:
            with self.subTest(name=name):
                self.assertEqual(self.run_hook(f"refs/heads/main {head} {name} {zero}\n").returncode, 0)

    def test_deleting_a_ref_needs_no_name_check(self):
        result = self.run_hook(f"(delete) {'0' * 40} refs/heads/{PHASE_BRANCH} {self.git('rev-parse', 'HEAD').stdout.strip()}\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_space_before_the_colon_is_caught(self):
        self.commit("Second", "Claude-Session : abc123")
        self.assertEqual(self.script("check-commit-trailers.sh", "range", "main~1..main").returncode, 1)


if __name__ == "__main__":
    unittest.main()
