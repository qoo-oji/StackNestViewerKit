"""Scripts/check-internal-markers.sh の試験（一時的な git リポジトリで、内部の印を止めることを確かめる）。"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
# 試験の文面も点検に掛からないよう、印は組み立てて作る。
PHASE = "G" + "99"
PLAN_REPO = "stackroom" + "-successor"
PLAN_DIR = "docs/super" + "powers/specs"


class InternalMarkerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-markers-")
        self.repo = Path(self.directory.name)
        (self.repo / "Scripts").mkdir()
        for name in ["check-internal-markers.sh", "internal-markers.txt"]:
            shutil.copy2(SCRIPTS / name, self.repo / "Scripts" / name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "shelfsmith")
        self.git("config", "user.email", "290546180+shelfsmith@users.noreply.github.com")
        self.write_and_commit("README.md", "plain text\n", "Initial")

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout

    def write_and_commit(self, name, text, message):
        (self.repo / name).write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").strip()

    def check(self, *args, stdin=""):
        return subprocess.run([str(self.repo / "Scripts/check-internal-markers.sh"), *args], cwd=self.repo,
                              input=stdin, capture_output=True, text=True)

    def test_clean_tree_passes_and_the_vocabulary_does_not_flag_itself(self):
        result = self.check("tree", "HEAD")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_marker_in_a_file_is_refused(self):
        self.write_and_commit("notes.md", f"see {PLAN_DIR}/x.md\n", "Add notes")
        result = self.check("tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("internal marker found in the files", result.stderr)

    def test_marker_in_a_message_is_refused(self):
        self.write_and_commit("a.txt", "a\n", f"Fix the bug from {PHASE}")
        result = self.check("range", "main~1..main")
        self.assertEqual(result.returncode, 1)
        self.assertIn("internal marker found in commit messages", result.stderr)

    def test_marker_added_and_removed_later_is_still_refused(self):
        base = self.git("rev-parse", "HEAD").strip()
        self.write_and_commit("a.txt", f"from {PLAN_REPO}\n", "Add a")
        tip = self.write_and_commit("a.txt", "clean\n", "Clean a")
        result = self.check("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {base}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("added by an outgoing commit", result.stderr)

    def test_marker_in_a_file_name_is_refused(self):
        self.write_and_commit(f"phase-{'g'}63-notes.txt", "x\n", "Add notes")
        result = self.check("range", "main~1..main")
        self.assertEqual(result.returncode, 1)
        self.assertIn("in a file name", result.stderr)

    def test_text_mode(self):
        self.assertEqual(self.check("text", stdin="nothing internal here\n").returncode, 0)
        self.assertEqual(self.check("text", stdin=f"see {PHASE}\n").returncode, 1)

    def test_usage_error(self):
        self.assertNotEqual(self.check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
