"""リリースの前の検査と GitHub Release の公開で共有する、版の番号・CHANGELOG・内部の印の読み方。

Version numbers, changelog parsing and internal-marker checks shared by the pre-release check and the publisher.
"""

from datetime import date
from pathlib import Path
import re

# 内部の印の語彙。pre-push と手作業の点検（check-internal-markers.sh）と同じ 1 つのファイルを読む。
MARKERS_FILE = Path(__file__).resolve().parent / "internal-markers.txt"

# 版を宣言するファイル。リリースの前の検査と公開が同じ読み方をする。
INFO = "Sources/StackNestViewerKitCore/StackNestViewerKitInfo.swift"


def stable_version(tag):
    """`X.Y.Z`（または `vX.Y.Z`）の確定版なら (X, Y, Z) を、ほかは None を返す。"""
    match = re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    return tuple(int(part) for part in match.groups()) if match else None


def release_entry(changelog, version):
    """CHANGELOG の `## [X.Y.Z] - YYYY-MM-DD` の項目を読み、(日付, 本文) を返す。

    見出しがちょうど 1 件でない・日付が無いか実在しない・本文が空なら ValueError。
    """
    if stable_version(version) is None:
        raise ValueError("版の番号は X.Y.Z の確定版で指定してください / Use a release version X.Y.Z")
    plain = re.escape(version.removeprefix("v"))
    headings = list(re.finditer(rf"^## \[{plain}\].*$", changelog, re.MULTILINE))
    if len(headings) != 1:
        raise ValueError("CHANGELOG にその版の見出しがちょうど 1 件必要です / The changelog needs exactly one heading for the version")
    heading = headings[0]
    match = re.fullmatch(rf"## \[{plain}\] - ([0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}})[ \t]*", heading.group(0))
    if not match:
        raise ValueError("見出しに YYYY-MM-DD の日付が必要です / The heading needs a YYYY-MM-DD date")
    try:
        released = date.fromisoformat(match.group(1))
    except ValueError as error:
        raise ValueError("見出しの日付が実在しません / The heading's date doesn't exist") from error
    notes = re.split(r"^## ", changelog[heading.end():], maxsplit=1, flags=re.MULTILINE)[0].strip()
    # 見出しだけの項目は空とみなす（Release の本文が見出し 1 行になるのを防ぐ）。
    if not any(line.strip() and not line.lstrip().startswith("#") for line in notes.splitlines()):
        raise ValueError("その版の本文が空です（見出しだけでは足りません） / The version's notes are empty (headings alone aren't enough)")
    return released, notes + "\n"


def marker_patterns(path=MARKERS_FILE):
    """内部の印の語彙（# で始まる行と空行を除いた拡張正規表現）。"""
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    patterns = [re.compile(line.strip()) for line in lines if line.strip() and not line.lstrip().startswith("#")]
    # 語彙が空なら何も見つからず通ってしまうので、番人のシェル（check-internal-markers.sh）と同じく止める。
    if not patterns:
        raise ValueError(f"内部の印の語彙が空です。検査できません / The internal-marker vocabulary is empty: {path}")
    return patterns


def private_markers(text, path=MARKERS_FILE):
    """公開の文面に出してはならない内部の印を、見つかった文字列の重複なしの名前順で返す。"""
    found = set()
    for pattern in marker_patterns(path):
        found.update(match.group(0) for match in pattern.finditer(text))
    return sorted(found)


def declared_versions(source):
    """StackNestViewerKitInfo.swift の `public static let version = "X.Y.Z"` の値の一覧（宣言が 1 つでなければ呼び出し側が止める）。"""
    return re.findall(r'^\s*public\s+static\s+let\s+version\s*=\s*"([^"\n]+)"\s*$', source, re.MULTILINE)
