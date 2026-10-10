"""Scripts/check-commit-trailers.sh と commit-msg フックの試験（一時的な git リポジトリで、Claude-Session: の行を
止めることを確かめる）。"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
# 試験の文面も内部の印の点検に掛からないよう、会話の URL は組み立てて作る。
SESSION_URL = "https://claude.ai/code/" + "session_example"


class CommitTrailerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-trailers-")
        self.repo = Path(self.directory.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "shelfsmith")
        self.git("config", "user.email", "290546180+shelfsmith@users.noreply.github.com")
        self.commit("Initial", "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args, check=True):
        return subprocess.run(["git", *args], cwd=self.repo, check=check, capture_output=True, text=True)

    def commit(self, subject, body):
        (self.repo / "file.txt").write_text(subject)
        self.git("add", "file.txt")
        self.git("commit", "-q", "-m", subject, "-m", body)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def run_script(self, *args, stdin=""):
        return subprocess.run([str(SCRIPTS / "check-commit-trailers.sh"), *args], cwd=self.repo, input=stdin,
                              capture_output=True, text=True)

    def test_range_without_session_line_passes(self):
        self.commit("Second", "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
        result = self.run_script("range", "main~1..main")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_range_with_session_line_is_refused(self):
        sha = self.commit("Second", "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"
                                    f"Claude-Session: {SESSION_URL}")
        result = self.run_script("range", "main~1..main")
        self.assertEqual(result.returncode, 1)
        self.assertIn(sha[:7], result.stderr)
        self.assertIn("Claude-Session:", result.stderr)

    def test_case_and_indentation_do_not_hide_the_line(self):
        self.commit("Second", f"  claude-session: {SESSION_URL}")
        self.assertEqual(self.run_script("range", "main~1..main").returncode, 1)

    def test_a_session_url_without_the_trailer_is_refused(self):
        self.commit("Second", f"See {SESSION_URL} for the discussion.")
        self.assertEqual(self.run_script("range", "main~1..main").returncode, 1)

    def test_mention_inside_a_sentence_is_allowed(self):
        self.commit("Second", "Explain why the Claude-Session: trailer is not used here.")
        self.assertEqual(self.run_script("range", "main~1..main").returncode, 0)

    def test_message_mode_reads_a_file(self):
        message = self.repo / "message.txt"
        message.write_text(f"Subject\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: {SESSION_URL}\n")
        refused = self.run_script("message", str(message))
        self.assertEqual(refused.returncode, 1)
        self.assertIn("message: Claude-Session:", refused.stderr)
        message.write_text("Subject\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n")
        self.assertEqual(self.run_script("message", str(message)).returncode, 0)

    def test_commit_msg_hook_refuses_the_commit(self):
        (self.repo / "Scripts" / "githooks").mkdir(parents=True)
        shutil.copy2(SCRIPTS / "check-commit-trailers.sh", self.repo / "Scripts" / "check-commit-trailers.sh")
        shutil.copy2(SCRIPTS / "githooks" / "commit-msg", self.repo / "Scripts" / "githooks" / "commit-msg")
        self.git("config", "core.hooksPath", "Scripts/githooks")
        (self.repo / "file.txt").write_text("hooked")
        self.git("add", "file.txt")
        refused = self.git("commit", "-q", "-m", "Hooked", "-m", f"Claude-Session: {SESSION_URL}", check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("commit-trailers: refused", refused.stderr)
        self.assertEqual(self.git("log", "--format=%s", "-1").stdout.strip(), "Initial", "コミットは作られていない")
        allowed = self.git("commit", "-q", "-m", "Hooked", "-m", "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>",
                           check=False)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)

    def test_pre_push_checks_new_commits_only(self):
        base = self.git("rev-parse", "HEAD").stdout.strip()
        tip = self.commit("Second", f"Claude-Session: {SESSION_URL}")
        refused = self.run_script("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {base}\n")
        self.assertEqual(refused.returncode, 1)
        allowed = self.run_script("pre-push", stdin=f"refs/heads/main {base} refs/heads/main {base}\n")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        deletion = self.run_script("pre-push", stdin=f"(delete) {'0' * 40} refs/heads/old {tip}\n")
        self.assertEqual(deletion.returncode, 0, deletion.stderr)
        new_branch = self.run_script("pre-push", stdin=f"refs/heads/new {tip} refs/heads/new {'0' * 40}\n")
        self.assertEqual(new_branch.returncode, 1, "新しい ref ではどの remote にも無いコミットをすべて見る")

    def test_usage_error(self):
        self.assertNotEqual(self.run_script().returncode, 0)


if __name__ == "__main__":
    unittest.main()
