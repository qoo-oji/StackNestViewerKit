#!/usr/bin/env python3
"""タグの CI がすべて通った後に、検証したコミットの CHANGELOG の項目から GitHub Release を作る（CI の release のジョブが呼ぶ）。

After every CI job for a tag passes, creates the GitHub Release from the verified commit's changelog entry.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
from release_support import INFO, declared_versions, private_markers, release_entry, stable_version  # noqa: E402


def run(*args):
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def paged(repository, resource):
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{repository}/{resource}"))
    return [item for page in pages for item in page]


def publish(tag, repository):
    version = stable_version(tag)
    if version is None or tag.startswith("v"):
        raise ValueError("タグは X.Y.Z の確定版で指定してください（v は付けない） / The tag must be a release version X.Y.Z, without a v prefix")
    tags = paged(repository, "tags")
    if not any(item["name"] == tag for item in tags):
        raise ValueError("公開先にそのタグがありません / The tag isn't on the remote")
    # タグが別のコミットへ動いた後に、古い CI の結果で公開しない。
    if run("gh", "api", f"repos/{repository}/commits/{tag}", "--jq", ".sha") != run("git", "rev-parse", "HEAD"):
        raise ValueError("公開先のタグと検証したコミットが違います / The remote tag doesn't point at the verified commit")
    for release in paged(repository, "releases"):
        if release["tag_name"] == tag:
            if release["draft"]:
                raise ValueError("同じタグの下書きがあります。確かめて手で公開してください / A draft exists; publish it by hand")
            print(f"公開済みなので変えません / Already published: {release['html_url']}")
            return
    # 上で HEAD がタグのコミットと同じだと確かめたので、HEAD の StackNestViewerKitInfo.version がタグのコミットの宣言になる。
    if declared_versions(run("git", "show", f"HEAD:{INFO}")) != [tag]:
        raise ValueError("StackNestViewerKitInfo.version がタグと違います / StackNestViewerKitInfo.version doesn't match the tag")
    # 作業ツリーではなく、CI が検証したコミットから本文を取る。
    _, notes = release_entry(run("git", "show", "HEAD:CHANGELOG.md"), tag)
    markers = private_markers(notes)
    if markers:
        raise ValueError(f"本文に公開できない印があります / Private markers in the notes: {', '.join(markers)}")
    versions = [stable_version(item["name"]) for item in tags]
    latest = version == max(value for value in versions if value is not None)
    with tempfile.TemporaryDirectory(prefix="kit-release-") as directory:
        notes_file = Path(directory) / "notes.md"
        notes_file.write_text(notes, encoding="utf-8")
        print(run("gh", "release", "create", tag, "--repo", repository, "--verify-tag",
                  "--title", f"StackNestViewerKit {tag}", "--notes-file", str(notes_file),
                  "--latest" if latest else "--latest=false"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--repo", required=True, help="公開先の OWNER/REPO / The OWNER/REPO to publish to")
    arguments = parser.parse_args()
    try:
        publish(arguments.tag, arguments.repo)
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError, TypeError, AttributeError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            detail = error.stderr
        elif isinstance(error, (KeyError, TypeError, AttributeError)):
            detail = f"API の応答の形が想定と違います / Unexpected API response shape: {type(error).__name__} {error}"
        else:
            detail = str(error)
        print(f"GitHub Release を作れませんでした / Couldn't publish the release: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
