"""Scripts/release.sh の試験（一時的なリポジトリと、公開先の代わりの bare リポジトリで）。"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
IDENTITY = {"GIT_AUTHOR_NAME": "shelfsmith", "GIT_COMMITTER_NAME": "shelfsmith",
            "GIT_AUTHOR_EMAIL": "290546180+shelfsmith@users.noreply.github.com",
            "GIT_COMMITTER_EMAIL": "290546180+shelfsmith@users.noreply.github.com"}
INFO = 'public enum StackNestViewerKitInfo {\n    public static let version = "{version}"\n}\n'
CHANGELOG = "# 変更履歴 / Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-10-20\n\n### 追加 / Added\n- 最初の版 / First release\n"


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-release-")
        base = Path(self.directory.name)
        self.repo = base / "repo"
        self.remote = base / "remote.git"
        (self.repo / "Scripts").mkdir(parents=True)
        for name in ["release.sh", "release-check.py", "release_support.py", "check-commit-trailers.sh",
                     "check-internal-markers.sh", "internal-markers.txt", "check-private-identifiers.sh"]:
            shutil.copy2(SCRIPTS / name, self.repo / "Scripts" / name)
        self.identifiers = base / "identifiers"
        self.identifiers.write_text("zzcanaryword\n")
        self.env = {**os.environ, **IDENTITY, "STACKNEST_PRIVATE_IDENTIFIERS_FILE": str(self.identifiers)}
        self.git("init", "-q", "-b", "main")
        self.write_release("0.1.0", CHANGELOG)
        self.commit("Prepare 0.1.0")
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)
        self.git("remote", "add", "origin", str(self.remote))

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args, env=None):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True,
                              env=env or self.env).stdout

    def write_release(self, version, changelog):
        info = self.repo / "Sources/StackNestViewerKitCore/StackNestViewerKitInfo.swift"
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_text(INFO.replace("{version}", version))
        (self.repo / "CHANGELOG.md").write_text(changelog)

    def commit(self, message, env=None):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message, env=env)

    def release(self, version="0.1.0"):
        return subprocess.run([str(self.repo / "Scripts/release.sh"), version], cwd=self.repo, capture_output=True,
                              text=True, env=self.env)

    def test_passes_for_a_clean_first_release(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.1.0 (2026-10-20)", result.stdout)

    def test_refuses_a_dirty_tree(self):
        (self.repo / "untracked.txt").write_text("x")
        self.assertIn("clean", self.release().stderr)

    def test_refuses_a_version_mismatch(self):
        self.write_release("0.0.9", CHANGELOG)
        self.commit("Wrong version")
        self.assertIn("StackNestViewerKitInfo.version", self.release().stderr)

    def test_refuses_a_version_that_is_not_newer(self):
        self.git("tag", "0.1.0")
        self.git("push", "-q", "origin", "0.1.0")
        self.assertIn("Not newer", self.release().stderr)

    def test_refuses_a_session_trailer(self):
        (self.repo / "note.txt").write_text("x")
        self.git("add", "note.txt")
        self.git("commit", "-q", "-m", "Note", "-m", "Claude-Session: https://claude.ai/code/" + "session_example")
        self.assertIn("check-commit-trailers.sh", self.release().stderr)

    def test_refuses_internal_markers_in_the_tree(self):
        (self.repo / "note.txt").write_text("see docs/super" + "powers/specs\n")
        self.commit("Note")
        self.assertIn("check-internal-markers.sh", self.release().stderr)

    def test_refuses_another_author(self):
        (self.repo / "note.txt").write_text("x")
        self.commit("Note", env={**self.env, "GIT_AUTHOR_NAME": "someone"})
        self.assertIn("shelfsmith", self.release().stderr)

    def test_refuses_private_markers_in_the_entry(self):
        phase = "G" + "99"  # 試験の文面が匿名性の点検に掛からないよう組み立てる
        self.write_release("0.1.0", CHANGELOG.replace("First release", f"First release ({phase})"))
        self.commit("Mention a phase")
        self.assertIn(phase, self.release().stderr)

    def test_refuses_identifiers_in_the_tree(self):
        (self.repo / "note.txt").write_text("zzcanaryword")
        self.commit("Note")
        self.assertIn("check-private-identifiers.sh", self.release().stderr)


if __name__ == "__main__":
    unittest.main()
