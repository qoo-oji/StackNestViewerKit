"""The push guards must fail closed: invalid UTF-8 in a patch, a failing awk/grep and a missing UTF-8 locale must stop
the push instead of reading as "no match", and patterns that rely on characters (kanji, full-width letters) must
still match. Identifiers here are dummies."""

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
# (pattern in the list, text that must match it). Each needs character semantics: `.` or a bracket over a kanji,
# a bracket holding U+3000, and -i over full-width letters.
CHARACTER_CASES = [
    ("山田.?太郎", "山田　太郎"),
    ("山田[ 　]?太郎", "山田　太郎"),
    ("ｙａｍａｄａ", "ＹＡＭＡＤＡ"),
]
NO_SUCH_LOCALE = "xx_XX.UTF-8"


class GuardBase(unittest.TestCase):
    script_name = ""
    support_files = []
    marker = ""          # what the guard looks for in these tests

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-guard-locale-")
        self.root = Path(self.directory.name)
        self.repo = self.root / "work"
        (self.repo / "Scripts").mkdir(parents=True)
        for name in [self.script_name, *self.support_files]:
            shutil.copy2(SCRIPTS / name, self.repo / "Scripts" / name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "shelfsmith")
        self.git("config", "user.email", "290546180+shelfsmith@users.noreply.github.com")
        self.base = self.commit("Initial", b"clean\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.setUpGuard()

    def setUpGuard(self):
        pass

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

    def path_with_stubs(self):
        return {"PATH": f"{self.bin}:{os.environ['PATH']}"}

    def run_script(self, *args, stdin="", env_extra=None, locale="en_US.UTF-8"):
        env = self.base_env()
        env["LC_ALL"] = locale
        env.update(env_extra or {})
        return subprocess.run([str(self.repo / "Scripts" / self.script_name), *args], cwd=self.repo, input=stdin,
                              capture_output=True, text=True, errors="replace", env=env)

    def base_env(self):
        return dict(os.environ)

    def grep_stub_failing_on_list_read(self):
        """A grep that dies part-way through reading the list (the call that uses -v) after printing one line."""
        real = shutil.which("grep")
        self.stub("grep", f'for a in "$@"; do [ "$a" = "-v" ] && {{ echo zzpartialzz; exit 2; }}; done\nexec {real} "$@"\n')

    def leak_then_remove(self, before, text=None):
        """One commit adds `before` and then the marker; the next removes the marker, so only the patch of the first
        commit still shows it (the tree, names and messages are clean). Returns the tip."""
        self.commit("Add", before + (text or self.marker).encode() + b"\n")
        return self.commit("Remove", before)


class PrivateIdentifiersLocale(GuardBase):
    script_name = "check-private-identifiers.sh"
    marker = CANARY

    def setUpGuard(self):
        self.identifiers = self.root / "identifiers.txt"
        self.set_list(CANARY)

    def set_list(self, *patterns):
        self.identifiers.write_text("\n".join(patterns) + "\n", encoding="utf-8")

    def base_env(self):
        return dict(os.environ, STACKNEST_PRIVATE_IDENTIFIERS_FILE=str(self.identifiers))

    def push_check(self, tip, **kwargs):
        return self.run_script("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {self.base}\n", **kwargs)

    def test_clean_patch_passes(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        result = self.push_check(tip)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_identifier_without_odd_bytes_stops(self):
        tip = self.leak_then_remove(b"plain\n")
        result = self.push_check(tip)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("added by an outgoing commit", result.stderr)

    def test_identifier_on_a_line_after_an_invalid_utf8_line_stops(self):
        tip = self.leak_then_remove(b"before \xff\xfe after\n")
        for locale in ["en_US.UTF-8", "ja_JP.UTF-8", "C"]:
            with self.subTest(locale=locale):
                result = self.push_check(tip, locale=locale)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("added by an outgoing commit", result.stderr)

    def test_invalid_utf8_line_first_in_the_hunk_stops(self):
        tip = self.leak_then_remove(b"\xff\xfe\n")
        self.assertEqual(self.push_check(tip).returncode, 1)

    def test_identifier_on_the_same_line_after_invalid_utf8_stops(self):
        tip = self.leak_then_remove(b"\xff\xfe ")
        for locale in ["en_US.UTF-8", "ja_JP.UTF-8", "C"]:
            with self.subTest(locale=locale):
                result = self.push_check(tip, locale=locale)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("added by an outgoing commit", result.stderr)

    def test_identifier_on_the_same_line_after_invalid_utf8_stops_in_text_mode(self):
        for locale in ["en_US.UTF-8", "C"]:
            with self.subTest(locale=locale):
                path = self.root / "raw.txt"
                path.write_bytes(b"\xff\xfe " + CANARY.encode() + b"\n")
                result = self.run_script("text", str(path), locale=locale)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_failing_awk_stops(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        self.stub("awk", "exit 2\n")
        result = self.push_check(tip, env_extra=self.path_with_stubs())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("awk failed", result.stderr)

    def test_failing_grep_stops(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        real = shutil.which("grep")
        # Fail only the identifier searches (they use -i); the list preparation must still work.
        self.stub("grep", f'for a in "$@"; do [ "$a" = "-i" ] && exit 2; done\nexec {real} "$@"\n')
        result = self.push_check(tip, env_extra=self.path_with_stubs())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("grep failed", result.stderr)

    def test_grep_failing_in_only_the_utf8_run_stops(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        real = shutil.which("grep")
        self.stub("grep", f'[ "$LC_ALL" = "en_US.UTF-8" ] && for a in "$@"; do [ "$a" = "-i" ] && exit 2; done\n'
                          f'exec {real} "$@"\n')
        result = self.push_check(tip, env_extra=self.path_with_stubs())
        self.assertNotEqual(result.returncode, 0)

    def test_missing_utf8_locale_stops(self):
        tip = self.commit("Clean", b"clean\nmore\n")
        env = {"STACKNEST_GUARD_UTF8_LOCALE": NO_SUCH_LOCALE}
        for args, stdin in [(("pre-push",), f"refs/heads/main {tip} refs/heads/main {self.base}\n"),
                            (("tree", tip), ""), (("text",), "clean\n")]:
            with self.subTest(mode=args[0]):
                result = self.run_script(*args, stdin=stdin, env_extra=env)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("locale", result.stderr)

    def test_character_patterns_stop_on_every_path(self):
        for pattern, text in CHARACTER_CASES:
            with self.subTest(pattern=pattern):
                self.set_list(pattern)
                tip = self.leak_then_remove(b"plain\n", text)
                # the patch only (the tree after the removal is clean)
                result = self.push_check(tip)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("added by an outgoing commit", result.stderr)
                # the tree
                leaked = self.commit("Leak", text.encode() + b"\n")
                result = self.run_script("tree", leaked)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("files of", result.stderr)
                # the text check (the gh-guarded path)
                result = self.run_script("text", stdin=text + "\n")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("found in the text", result.stderr)
                self.commit("Clean again", b"clean\n")

    def test_character_pattern_does_not_stop_clean_text(self):
        self.set_list("山田.?太郎")
        self.assertEqual(self.run_script("text", stdin="山田花子\n").returncode, 0)

    def test_character_pattern_on_the_same_line_as_invalid_utf8_stops(self):
        self.set_list("山田.?太郎")
        tip = self.leak_then_remove(b"\xff ", "山田　太郎")
        for locale in ["en_US.UTF-8", "C"]:
            with self.subTest(locale=locale, mode="pre-push"):
                result = self.push_check(tip, locale=locale)
                self.assertEqual(result.returncode, 1, result.stderr)
            with self.subTest(locale=locale, mode="text"):
                path = self.root / "raw.txt"
                path.write_bytes(b"\xff " + "山田　太郎\n".encode())
                self.assertEqual(self.run_script("text", str(path), locale=locale).returncode, 1)
        self.set_list("山田.?太郎")
        clean = self.root / "clean.txt"
        clean.write_bytes(b"\xff " + "山田花子\n".encode())
        self.assertEqual(self.run_script("text", str(clean)).returncode, 0)

    def test_text_with_several_files_does_not_join_lines(self):
        self.set_list("^" + CANARY)
        first = self.root / "first.txt"
        second = self.root / "second.txt"
        first.write_bytes(b"abc")                       # no trailing newline
        second.write_bytes(CANARY.encode() + b"\n")
        self.assertEqual(self.run_script("text", str(first), str(second)).returncode, 1)

    def test_failure_while_reading_the_list_stops(self):
        self.grep_stub_failing_on_list_read()
        result = self.run_script("text", stdin="clean\n", env_extra=self.path_with_stubs())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read the identifier list", result.stderr)


class InternalMarkersLocale(GuardBase):
    """Same holes in check-internal-markers.sh (it also reads patches through awk)."""

    script_name = "check-internal-markers.sh"
    support_files = ["internal-markers.txt"]
    marker = "G" + "99"

    def range_check(self, **kwargs):
        return self.run_script("range", f"{self.base}..HEAD", **kwargs)

    def test_clean_passes(self):
        self.commit("Clean", b"clean\nmore\n")
        self.assertEqual(self.range_check().returncode, 0)

    def test_marker_without_odd_bytes_stops(self):
        self.leak_then_remove(b"plain\n")
        self.assertEqual(self.range_check().returncode, 1)

    def test_marker_after_invalid_utf8_line_stops(self):
        self.leak_then_remove(b"before \xff\xfe after\n")
        result = self.range_check()
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_marker_on_the_same_line_after_invalid_utf8_stops(self):
        self.leak_then_remove(b"\xff\xfe ")
        for locale in ["en_US.UTF-8", "C"]:
            with self.subTest(locale=locale):
                self.assertEqual(self.range_check(locale=locale).returncode, 1)

    def test_failing_awk_stops(self):
        self.commit("Clean", b"clean\nmore\n")
        self.stub("awk", "exit 2\n")
        result = self.range_check(env_extra=self.path_with_stubs())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("awk failed", result.stderr)

    def test_missing_utf8_locale_stops(self):
        self.commit("Clean", b"clean\nmore\n")
        result = self.range_check(env_extra={"STACKNEST_GUARD_UTF8_LOCALE": NO_SUCH_LOCALE})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("locale", result.stderr)

    def test_the_word_is_matched_but_not_a_neighbour(self):
        # The list writes the word as 裁(定); 裁判 and 裁可 are other words (a byte bracket would match them).
        for locale in ["en_US.UTF-8", "C"]:
            with self.subTest(locale=locale):
                self.assertEqual(self.run_script("text", stdin="裁判 裁可\n", locale=locale).returncode, 0)
                self.assertEqual(self.run_script("text", stdin="裁" + "定\n", locale=locale).returncode, 1)

    def test_failure_while_reading_the_list_stops(self):
        self.grep_stub_failing_on_list_read()
        result = self.run_script("text", stdin="clean\n", env_extra=self.path_with_stubs())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read the marker list", result.stderr)


if __name__ == "__main__":
    unittest.main()
