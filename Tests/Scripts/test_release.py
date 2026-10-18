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
CONTRIBUTOR = {"GIT_AUTHOR_NAME": "contributor", "GIT_COMMITTER_NAME": "contributor",
               "GIT_AUTHOR_EMAIL": "1+contributor@users.noreply.github.com",
               "GIT_COMMITTER_EMAIL": "1+contributor@users.noreply.github.com"}
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
        self.git("config", "core.hooksPath", "Scripts/githooks")
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

    def refused(self, text, version="0.1.0"):
        result = self.release(version)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(text, result.stderr)
        return result

    def test_passes_for_a_clean_first_release(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.1.0 (2026-10-20)", result.stdout)

    def test_refuses_a_dirty_tree(self):
        (self.repo / "untracked.txt").write_text("x")
        self.refused("clean")

    def test_refuses_a_version_mismatch(self):
        self.write_release("0.0.9", CHANGELOG)
        self.commit("Wrong version")
        self.refused("StackNestViewerKitInfo.version")

    def test_refuses_a_version_that_is_not_newer(self):
        self.git("tag", "0.1.0")
        self.git("push", "-q", "origin", "0.1.0")
        self.refused("Not newer")

    def test_refuses_a_session_trailer(self):
        (self.repo / "note.txt").write_text("x")
        self.git("add", "note.txt")
        self.git("commit", "-q", "-m", "Note", "-m", "Claude-Session: https://claude.ai/code/" + "session_example")
        self.refused("check-commit-trailers.sh")

    def test_refuses_internal_markers_in_the_tree(self):
        (self.repo / "note.txt").write_text("see docs/super" + "powers/specs\n")
        self.commit("Note")
        self.refused("check-internal-markers.sh")

    def test_refuses_another_author(self):
        (self.repo / "note.txt").write_text("x")
        self.commit("Note", env={**self.env, "GIT_AUTHOR_NAME": "someone"})
        self.refused("shelfsmith")

    def test_refuses_private_markers_in_the_entry(self):
        phase = "G" + "99"  # 試験の文面が匿名性の点検に掛からないよう組み立てる
        self.write_release("0.1.0", CHANGELOG.replace("First release", f"First release ({phase})"))
        self.commit("Mention a phase")
        self.refused(phase)

    def test_refuses_identifiers_in_the_tree(self):
        (self.repo / "note.txt").write_text("zzcanaryword")
        self.commit("Note")
        self.refused("check-private-identifiers.sh")


    def test_refuses_a_marker_added_and_removed_within_the_range(self):
        # The tree is clean at HEAD, so only the range check can see it.
        (self.repo / "note.txt").write_text("see docs/super" + "powers/specs\n")
        self.commit("Add note")
        self.git("rm", "-q", "note.txt")
        self.git("commit", "-q", "-m", "Remove note")
        self.refused("check-internal-markers.sh")

    def test_refuses_a_committer_only_mismatch(self):
        (self.repo / "note.txt").write_text("x")
        self.commit("Note", env={**self.env, "GIT_COMMITTER_NAME": "someone"})
        self.refused("shelfsmith")

    def test_names_the_changelog_entry_when_it_holds_a_marker(self):
        phase = "G" + "99"
        self.write_release("0.1.0", CHANGELOG.replace("First release", f"First release ({phase})"))
        self.commit("Mention a phase")
        self.refused("changelog entry")

    def test_refuses_an_entry_with_only_a_heading(self):
        self.write_release("0.1.0", CHANGELOG.replace("- 最初の版 / First release\n", ""))
        self.commit("Empty entry")
        self.refused("empty")

    def test_refuses_when_the_hooks_are_not_installed(self):
        self.git("config", "--unset", "core.hooksPath")
        self.refused("core.hooksPath")
        self.git("config", "core.hooksPath", ".git/hooks")
        self.refused("core.hooksPath")

    def test_refuses_a_tag_whose_commit_is_missing_locally(self):
        other = Path(self.directory.name) / "other"
        subprocess.run(["git", "clone", "-q", str(self.remote), str(other)], check=True, capture_output=True)
        (other / "x.txt").write_text("x")
        for args in (["add", "x.txt"], ["commit", "-q", "-m", "Elsewhere"], ["tag", "0.0.9"], ["push", "-q", "origin", "0.0.9"]):
            subprocess.run(["git", *args], cwd=other, check=True, capture_output=True, env=self.env)
        self.refused("git fetch --tags")

    def test_uses_the_remote_tag_not_the_local_one_as_the_range_base(self):
        self.git("tag", "0.0.9")
        self.git("push", "-q", "origin", "0.0.9")
        (self.repo / "note.txt").write_text("see docs/super" + "powers/specs\n")
        self.commit("Add note")
        self.git("rm", "-q", "note.txt")
        self.git("commit", "-q", "-m", "Remove note")
        self.git("tag", "-f", "0.0.9")  # the local tag moves past the commit that added the marker
        self.refused("check-internal-markers.sh")

    def accept(self, *lines):
        (self.repo / "Scripts/accepted-contributors.txt").write_text("# accepted\n\n" + "".join(f"{line}\n" for line in lines))
        self.commit("Accept contributors")

    def contribute(self, env):
        (self.repo / "note.txt").write_text("x")
        self.commit("Contribution", env={**self.env, **env})
        return self.git("rev-parse", "--short", "HEAD").strip()

    def test_passes_a_listed_contributor(self):
        self.accept("contributor <1+contributor@users.noreply.github.com>")
        self.contribute(CONTRIBUTOR)
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_passes_a_listed_author_committed_by_shelfsmith(self):
        self.accept("contributor <1+contributor@users.noreply.github.com>")
        self.contribute({key: value for key, value in CONTRIBUTOR.items() if key.startswith("GIT_AUTHOR")})
        self.assertEqual(self.release().returncode, 0)

    def test_refuses_an_unlisted_contributor_and_names_the_commit(self):
        self.accept("contributor <1+contributor@users.noreply.github.com>")
        commit = self.contribute({**CONTRIBUTOR, "GIT_AUTHOR_NAME": "other", "GIT_COMMITTER_NAME": "other",
                                  "GIT_AUTHOR_EMAIL": "2+other@users.noreply.github.com",
                                  "GIT_COMMITTER_EMAIL": "2+other@users.noreply.github.com"})
        self.refused(commit)

    def test_refuses_a_listed_name_with_another_email(self):
        self.accept("contributor <1+contributor@users.noreply.github.com>")
        self.contribute({**CONTRIBUTOR, "GIT_AUTHOR_EMAIL": "contributor@example.com"})
        self.refused("shelfsmith")

    def test_refuses_a_contributor_without_a_list(self):
        self.contribute(CONTRIBUTOR)
        self.refused("shelfsmith")

    def test_refuses_a_list_entry_that_is_not_a_noreply_address(self):
        for entry in ["someone <someone@example.com>", "someone <@users.noreply.github.com>",
                      "someone <a@b@users.noreply.github.com>"]:
            with self.subTest(entry=entry):
                self.accept(entry)
                self.refused("noreply")

    def test_refuses_a_malformed_list_line(self):
        for entry in ["1+contributor@users.noreply.github.com", "contributor", "<1+contributor@users.noreply.github.com>",
                      "contributor <1+contributor@users.noreply.github.com> extra"]:
            with self.subTest(entry=entry):
                self.accept(entry)
                self.refused("Name <email>")

    def test_refuses_a_list_entry_with_an_uppercase_domain(self):
        self.accept("contributor <1+contributor@USERS.NOREPLY.GITHUB.COM>")
        self.refused("noreply")

    def test_refuses_a_list_line_with_a_double_space_or_a_tab(self):
        for entry in ["contributor  <1+contributor@users.noreply.github.com>",
                      "contributor\t<1+contributor@users.noreply.github.com>"]:
            with self.subTest(entry=entry):
                self.accept(entry)
                self.refused("Name <email>")

    def test_refuses_a_listed_email_with_another_name(self):
        self.accept("contributor <1+contributor@users.noreply.github.com>")
        self.contribute({**CONTRIBUTOR, "GIT_AUTHOR_NAME": "renamed"})
        self.refused("shelfsmith")

    def test_refuses_a_shelfsmith_author_with_an_unlisted_committer(self):
        self.accept("contributor <1+contributor@users.noreply.github.com>")
        commit = self.contribute({"GIT_COMMITTER_NAME": "other", "GIT_COMMITTER_EMAIL": "2+other@users.noreply.github.com"})
        self.refused(commit)

    def test_refuses_a_list_edit_that_is_not_by_shelfsmith(self):
        (self.repo / "Scripts/accepted-contributors.txt").write_text("contributor <1+contributor@users.noreply.github.com>\n")
        self.commit("Accept myself", env={**self.env, **CONTRIBUTOR})
        commit = self.git("rev-parse", "--short", "HEAD").strip()
        result = self.refused("changed Scripts/accepted-contributors.txt")
        self.assertIn(commit, result.stderr)

    def test_refuses_a_list_edit_brought_in_by_a_merge(self):
        self.git("checkout", "-q", "-b", "outside")
        (self.repo / "Scripts/accepted-contributors.txt").write_text("contributor <1+contributor@users.noreply.github.com>\n")
        self.commit("Accept myself", env={**self.env, **CONTRIBUTOR})
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--no-ff", "-m", "Merge outside", "outside")
        self.refused("changed Scripts/accepted-contributors.txt")

    def test_refuses_shelfsmith_in_the_list(self):
        self.accept("shelfsmith <290546180+shelfsmith@users.noreply.github.com>")
        self.refused("never listed")


if __name__ == "__main__":
    unittest.main()
