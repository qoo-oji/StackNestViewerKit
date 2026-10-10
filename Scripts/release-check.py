#!/usr/bin/env python3
"""リリースの前の検査。タグの作成・push はしない（作者の指示があるときに手で行う）。

Pre-release checks. This never creates tags or pushes.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
from release_support import INFO, declared_versions, private_markers, release_entry, stable_version  # noqa: E402

IDENTITY = ("shelfsmith", "290546180+shelfsmith@users.noreply.github.com")


class CheckError(Exception):
    pass


def git(*args):
    # 認証の入力待ちや応答しない接続で検査が止まらないようにする。
    try:
        result = subprocess.run(
            ["git", *args], cwd=ROOT, text=True, capture_output=True, timeout=30,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )
    except subprocess.TimeoutExpired as error:
        raise CheckError("git が 30 秒以内に答えませんでした / git did not answer within 30 seconds") from error
    if result.returncode:
        raise CheckError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def run_script(name, *args):
    result = subprocess.run([str(ROOT / "Scripts" / name), *args], cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise CheckError(f"{name}: {result.stderr.strip()}")


def main():
    parser = argparse.ArgumentParser(
        prog="Scripts/release.sh",
        description="リリースの前の検査（タグの作成・push はしない） / Pre-release checks (no tagging or pushing)",
    )
    parser.add_argument("version", help="公開する版（例: 0.1.0） / The version to release (e.g. 0.1.0)")
    parser.add_argument("--remote", default="origin", help="公開先の remote（既定: origin） / The remote (default: origin)")
    arguments = parser.parse_args()
    try:
        requested = stable_version(arguments.version)
        if requested is None or arguments.version.startswith("v"):
            raise CheckError("版の番号は X.Y.Z で指定してください / Give the version as X.Y.Z")
        if Path(git("rev-parse", "--show-toplevel").strip()).resolve() != ROOT:
            raise CheckError("このリポジトリの Scripts/release.sh を実行してください / Run this repository's Scripts/release.sh")
        # フックが入っていない clone（別の Mac など）では、push の番人が働かない。
        try:
            hooks = git("config", "--get", "core.hooksPath").strip()
        except CheckError:
            hooks = ""
        if hooks != "Scripts/githooks":
            raise CheckError("git の core.hooksPath が Scripts/githooks ではありません。`git config core.hooksPath Scripts/githooks` を実行してください / "
                             "core.hooksPath isn't Scripts/githooks; run `git config core.hooksPath Scripts/githooks`")
        if git("status", "--porcelain=v1", "--untracked-files=all").strip():
            raise CheckError("作業ツリーがクリーンではありません（未追跡のファイルを含む） / The working tree isn't clean")

        released, notes = release_entry(git("show", "HEAD:CHANGELOG.md"), arguments.version)
        markers = private_markers(notes)
        if markers:
            raise CheckError(f"CHANGELOG の項目に公開できない印があります / Private markers in the changelog entry: {', '.join(markers)}")
        if declared_versions(git("show", f"HEAD:{INFO}")) != [arguments.version]:
            raise CheckError("StackNestViewerKitInfo.version を公開する版に合わせてください / Set StackNestViewerKitInfo.version to the version")

        # 手元のタグの一覧は古いことがあるので、公開先に直接たずねる。
        tags = []
        for line in git("ls-remote", "--tags", "--refs", "--", arguments.remote).splitlines():
            fields = line.split()
            if len(fields) != 2 or not fields[1].startswith("refs/tags/"):
                raise CheckError("公開先から読めないタグの一覧が返りました / The remote returned an unreadable tag list")
            tag = fields[1].removeprefix("refs/tags/")
            if stable_version(tag) is not None:
                tags.append((stable_version(tag), tag, fields[0]))
        latest = max(tags) if tags else None
        if latest is not None and requested <= latest[0]:
            raise CheckError(f"{arguments.version} は公開済みの最新のタグ {latest[1]} より新しくありません / Not newer than {latest[1]}")

        # 範囲の起点は、手元の同名のタグではなく、公開先のタグが指すコミットにする（手元のタグは動かせるため）。
        if latest is not None:
            try:
                base = git("rev-parse", "--verify", "--quiet", f"{latest[2]}^{{commit}}").strip()
            except CheckError as error:
                raise CheckError(f"公開済みのタグ {latest[1]} のコミットが手元にありません。`git fetch --tags` を実行してください / "
                                 f"The commit of the published tag {latest[1]} isn't here; run `git fetch --tags`") from error
            since = [f"{base}..HEAD"]
        else:
            since = ["HEAD"]
        for line in git("log", "--format=%an%x09%ae%x09%cn%x09%ce", *since).splitlines():
            name, email, committer, committer_email = line.split("\t")
            if (name, email) != IDENTITY or (committer, committer_email) != IDENTITY:
                raise CheckError("shelfsmith 以外の作成者・コミッタのコミットがあります / A commit isn't by shelfsmith")
        run_script("check-commit-trailers.sh", "range", *since)
        run_script("check-internal-markers.sh", "range", *since)
        run_script("check-internal-markers.sh", "tree", "HEAD")
        run_script("check-private-identifiers.sh", "tree", "HEAD")

        print(f"リリースの前の検査を通りました / Pre-release checks passed: {arguments.version} ({released.isoformat()})")
        print(f"公開済みの最新のタグ / Latest published tag: {latest[1] if latest else 'なし / none'}")
        print("作業ツリー / Working tree: clean")
    except (CheckError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
