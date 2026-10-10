"""Scripts/release_support.py の単体の試験。"""

from datetime import date
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from release_support import declared_versions, marker_patterns, private_markers, release_entry, stable_version  # noqa: E402

CHANGELOG = """# 変更履歴 / Changelog

## [Unreleased]

## [0.2.0] - 2026-11-01

### 追加 / Added
- 何か / Something

## [0.1.0] - 2026-10-20

### 追加 / Added
- 最初の版 / First release
"""


class StableVersionTests(unittest.TestCase):
    def test_accepts_release_versions(self):
        self.assertEqual(stable_version("0.1.0"), (0, 1, 0))
        self.assertEqual(stable_version("v1.20.3"), (1, 20, 3))

    def test_rejects_others(self):
        for tag in ["0.1", "01.0.0", "0.1.0-beta", "latest", "1.0.0.0", ""]:
            self.assertIsNone(stable_version(tag), tag)


class ReleaseEntryTests(unittest.TestCase):
    def test_reads_the_entry(self):
        released, notes = release_entry(CHANGELOG, "0.1.0")
        self.assertEqual(released, date(2026, 10, 20))
        self.assertEqual(notes, "### 追加 / Added\n- 最初の版 / First release\n")

    def test_stops_at_the_next_heading(self):
        _, notes = release_entry(CHANGELOG, "0.2.0")
        self.assertNotIn("0.1.0", notes)

    def test_rejects_missing_undated_empty_or_duplicate(self):
        with self.assertRaises(ValueError):
            release_entry(CHANGELOG, "0.3.0")
        with self.assertRaises(ValueError):
            release_entry("## [0.1.0]\n- x\n", "0.1.0")
        with self.assertRaises(ValueError):
            release_entry("## [0.1.0] - 2026-02-30\n- x\n", "0.1.0")
        with self.assertRaises(ValueError):
            release_entry("## [0.1.0] - 2026-10-20\n\n## [0.0.1] - 2026-10-01\n- x\n", "0.1.0")
        with self.assertRaises(ValueError):
            release_entry(CHANGELOG + "\n## [0.1.0] - 2026-10-21\n- again\n", "0.1.0")


    def test_rejects_an_entry_with_only_headings(self):
        with self.assertRaises(ValueError):
            release_entry("## [0.1.0] - 2026-10-20\n\n### 追加 / Added\n\n### 修正 / Fixed\n\n## [0.0.1] - 2026-10-01\n- x\n", "0.1.0")


class DeclaredVersionTests(unittest.TestCase):
    def test_reads_the_declaration(self):
        self.assertEqual(declared_versions('public enum I {\n    public static let version = "0.1.0"\n}\n'), ["0.1.0"])
        self.assertEqual(declared_versions('let version: String = "0.1.0"\n'), [])


class PrivateMarkerTests(unittest.TestCase):
    def test_finds_every_kind_of_marker(self):
        # 試験の文面も匿名性の点検に掛からないよう、印は組み立てて作る。
        samples = {
            "G" + "99": "G" + "99",
            "fixed in G" + "98b": "G" + "98",
            "/" + "Users/someone/x": "/" + "Users/",
            "\u88c1\u5b9a 5": "\u88c1\u5b9a",
            "stackroom" + "-successor/docs": "stackroom" + "-successor",
            "docs/super" + "powers/specs": "super" + "powers",
            "analysis/decisions" + ".md": "decisions" + ".md",
            "work/qooviewer" + "-fork": "qooviewer" + "-fork",
            "2026-10-08-phase" + "-g63-design.md": "phase" + "-g6",
            "https://claude.ai/code/" + "session_x": "claude.ai/code/" + "session_",
        }
        for text, marker in samples.items():
            self.assertEqual(private_markers(text), [marker], text)

    def test_plain_notes_pass(self):
        self.assertEqual(private_markers("- Add StackNestBookSession / 本のセッションを追加\n- HTTP 502\n- Co-Authored-By"), [])

    def test_the_vocabulary_file_does_not_flag_itself(self):
        vocabulary = (Path(__file__).resolve().parents[2] / "Scripts/internal-markers.txt").read_text()
        self.assertEqual(private_markers(vocabulary), [])

    def test_an_empty_vocabulary_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            for content in ["", "# comments only\n\n   \n"]:
                vocabulary = Path(directory) / "markers.txt"
                vocabulary.write_text(content)
                with self.assertRaises(ValueError):
                    marker_patterns(vocabulary)
                with self.assertRaises(ValueError):
                    private_markers("anything", vocabulary)


if __name__ == "__main__":
    unittest.main()
