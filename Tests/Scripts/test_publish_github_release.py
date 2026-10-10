"""Scripts/publish-github-release.py の試験（gh を偽物に差し替え、一時的なリポジトリで）。"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
CHANGELOG = "# 変更履歴 / Changelog\n\n## [0.1.0] - 2026-10-20\n\n### 追加 / Added\n- 最初の版 / First release\n"

FAKE_GH = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, sys
    state = json.load(open(os.environ["FAKE_GH_STATE"]))
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps(sys.argv[1:]) + "\\n")
    args = sys.argv[1:]
    if args[:3] == ["api", "--paginate", "--slurp"]:
        resource = args[3].rsplit("/", 1)[1]
        print(json.dumps([state[resource]]))
    elif args[0] == "api" and "/commits/" in args[1]:
        print(state["sha"])
    elif args[:2] == ["release", "create"]:
        notes = open(args[args.index("--notes-file") + 1]).read()
        with open(os.environ["FAKE_GH_LOG"], "a") as log:
            log.write(json.dumps({"notes": notes}) + "\\n")
        print("https://github.com/example/kit/releases/tag/" + args[2])
    else:
        sys.exit(1)
    ''')


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kit-publish-")
        base = Path(self.directory.name)
        self.repo = base / "repo"
        (self.repo / "Scripts").mkdir(parents=True)
        for name in ["publish-github-release.py", "release_support.py", "internal-markers.txt"]:
            shutil.copy2(SCRIPTS / name, self.repo / "Scripts" / name)
        (self.repo / "CHANGELOG.md").write_text(CHANGELOG)
        env = {**os.environ, "GIT_AUTHOR_NAME": "shelfsmith", "GIT_COMMITTER_NAME": "shelfsmith",
               "GIT_AUTHOR_EMAIL": "s@example.com", "GIT_COMMITTER_EMAIL": "s@example.com"}
        for args in (["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "Release"]):
            subprocess.run(["git", *args], cwd=self.repo, check=True, env=env)
        self.sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, check=True, capture_output=True,
                                  text=True).stdout.strip()
        bin_dir = base / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.state_file = base / "state.json"
        self.log_file = base / "log.jsonl"
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_GH_STATE": str(self.state_file),
                    "FAKE_GH_LOG": str(self.log_file)}

    def tearDown(self):
        self.directory.cleanup()

    def publish(self, tags=("0.1.0",), sha=None, releases=()):
        self.state_file.write_text(json.dumps({"tags": [{"name": t} for t in tags], "sha": sha or self.sha,
                                               "releases": list(releases)}))
        return subprocess.run([str(self.repo / "Scripts/publish-github-release.py"), "0.1.0", "--repo", "example/kit"],
                              cwd=self.repo, capture_output=True, text=True, env=self.env)

    def log(self):
        return [json.loads(line) for line in self.log_file.read_text().splitlines()] if self.log_file.exists() else []

    def test_creates_the_release_from_the_changelog(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(entry for entry in self.log() if isinstance(entry, list) and entry[:2] == ["release", "create"])
        self.assertIn("--verify-tag", create)
        self.assertIn("StackNestViewerKit 0.1.0", create)
        self.assertIn("--latest", create)
        notes = next(entry["notes"] for entry in self.log() if isinstance(entry, dict))
        self.assertEqual(notes, "### 追加 / Added\n- 最初の版 / First release\n")

    def test_refuses_a_missing_tag(self):
        self.assertEqual(self.publish(tags=("0.0.9",)).returncode, 1)

    def test_refuses_a_moved_tag(self):
        self.assertEqual(self.publish(sha="0" * 40).returncode, 1)

    def test_keeps_an_existing_release(self):
        result = self.publish(releases=[{"tag_name": "0.1.0", "draft": False, "html_url": "https://example.com/r"}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(isinstance(e, list) and e[:2] == ["release", "create"] for e in self.log()))

    def test_refuses_a_draft(self):
        self.assertEqual(self.publish(releases=[{"tag_name": "0.1.0", "draft": True, "html_url": "x"}]).returncode, 1)

    def test_refuses_internal_markers_in_the_notes(self):
        changelog = CHANGELOG.replace("First release", "First release (" + "G" + "99)")
        (self.repo / "CHANGELOG.md").write_text(changelog)
        env = {**os.environ, "GIT_AUTHOR_NAME": "shelfsmith", "GIT_COMMITTER_NAME": "shelfsmith",
               "GIT_AUTHOR_EMAIL": "s@example.com", "GIT_COMMITTER_EMAIL": "s@example.com"}
        subprocess.run(["git", "commit", "-qam", "Mention"], cwd=self.repo, check=True, env=env)
        self.sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, check=True, capture_output=True,
                                  text=True).stdout.strip()
        result = self.publish()
        self.assertEqual(result.returncode, 1)
        self.assertIn("G" + "99", result.stderr)

    def test_an_older_tag_is_not_marked_latest(self):
        result = self.publish(tags=("0.1.0", "0.2.0"))
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(entry for entry in self.log() if isinstance(entry, list) and entry[:2] == ["release", "create"])
        self.assertIn("--latest=false", create)


if __name__ == "__main__":
    unittest.main()
