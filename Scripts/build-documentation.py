#!/usr/bin/env python3
"""DocC の文書を作り、記事と README の Swift の例をすべて型検査し、静的に公開するサイトを書き出す。

Builds the DocC documentation, typechecks every Swift example in the articles and the README, and writes a site for
static hosting.
"""

import argparse
import html
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "Tests/StackNestViewerKitPublicAPITests/IntegrationExample.swift"
EXAMPLE_COPIES = [ROOT / f"Samples/Sources/{target}/IntegrationExample.swift"
                  for target in ("HostModeMainActor", "HostModeSwift5", "HostModeSwift6")]
README_BLOCK = re.compile(r"<!-- integration-example:begin -->\n```swift\n(.*?)```\n<!-- integration-example:end -->", re.S)
SWIFT_BLOCK = re.compile(r"^```swift\s*\n(.*?)^```\s*$", re.M | re.S)
MODULES = [("StackNestViewerKit", "kit"), ("StackNestViewerKitCore", "core")]


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def check_integration_example():
    """README・GettingStarted・HostMode の統合例が、試験がコンパイルする例と 1 字も違わないこと。"""
    canonical = EXAMPLE.read_text()
    readme = README_BLOCK.search((ROOT / "README.md").read_text())
    if readme is None or readme.group(1) != canonical:
        raise RuntimeError("README の統合例が IntegrationExample.swift と違う / README example differs")
    started = SWIFT_BLOCK.search((ROOT / "Sources/StackNestViewerKit/StackNestViewerKit.docc/GettingStarted.md").read_text())
    if started is None or started.group(1) != canonical:
        raise RuntimeError("GettingStarted の統合例が IntegrationExample.swift と違う / GettingStarted example differs")
    for copy in EXAMPLE_COPIES:
        if copy.read_text() != canonical:
            raise RuntimeError(f"{copy.relative_to(ROOT)} が IntegrationExample.swift と違う / differs")
    print("統合例は 1 つ / Integration example is identical everywhere", flush=True)


def typecheck_examples(derived_data):
    """記事の Swift の例と README の統合例を、1 つずつ独立したファイルとして型検査する（警告もエラー）。"""
    sources = []
    for article in sorted((ROOT / "Sources").glob("**/*.docc/*.md")):
        for index, code in enumerate(SWIFT_BLOCK.findall(article.read_text()), 1):
            sources.append((f"{article.relative_to(ROOT)} #{index}", code))
    sources.append(("README.md integration example", README_BLOCK.search((ROOT / "README.md").read_text()).group(1)))
    with tempfile.TemporaryDirectory(prefix="kit-doc-examples-") as directory:
        for number, (label, code) in enumerate(sources, 1):
            print(f"型検査 / Typecheck: {label}", flush=True)
            source = Path(directory) / f"Example{number}.swift"
            source.write_text(code)
            run("xcrun", "swiftc", "-swift-version", "6", "-typecheck", "-warnings-as-errors",
                "-target", f"{platform.machine()}-apple-macosx14.0",
                "-module-cache-path", derived_data / "ExampleModuleCache",
                "-I", derived_data / "Build/Products/Debug", source)
    print(f"型検査した例 / Typechecked examples: {len(sources)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="空の出力ディレクトリ / An empty output directory")
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--base-path", default="/StackNestViewerKit", help="公開の URL の接頭辞 / Hosting URL prefix")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    derived = args.derived_data.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output-dir は空にしてください / output-dir must be empty")
    base = "/" + args.base_path.strip("/") if args.base_path.strip("/") else ""
    check_integration_example()
    run("xcodebuild", "docbuild", "-scheme", "StackNestViewerKit", "-destination", "platform=macOS",
        "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", "OTHER_DOCC_FLAGS=--warnings-as-errors")
    typecheck_examples(derived)
    output.mkdir(parents=True, exist_ok=True)
    for module, path in MODULES:
        archive = derived / "Build/Products/Debug" / f"{module}.doccarchive"
        run("xcrun", "docc", "process-archive", "transform-for-static-hosting", archive,
            "--output-path", output / path, "--hosting-base-path", f"{base}/{path}")
        if not (output / path / "documentation" / module.lower() / "index.html").is_file():
            raise RuntimeError(f"公開のページがありません / Missing page: {module}")
    revision = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    (output / "index.html").write_text(f'''<!doctype html>
<html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>StackNestViewerKit — Documentation</title>
<style>body{{font:18px/1.7 system-ui;max-width:46rem;margin:8vh auto;padding:0 1.5rem}}li{{margin:.8rem 0}}small{{color:#666}}</style>
<h1>StackNestViewerKit</h1>
<p>StackNest の本を外部ビューアで読むための部品。<br>A kit for reading StackNest books in an external viewer.</p>
<ul>
<li><a href="{base}/kit/documentation/stacknestviewerkit/gettingstarted">始め方 / Getting started</a></li>
<li><a href="{base}/kit/documentation/stacknestviewerkit">StackNestViewerKit — セッション・書き戻し / Session and progress</a></li>
<li><a href="{base}/core/documentation/stacknestviewerkitcore">StackNestViewerKitCore — 形式・宣言・エラー / Format, declaration, errors</a></li>
<li><a href="https://github.com/shelfsmith/StackNestViewerKit/blob/main/Documentation/BookReferenceFormat.md">参照ファイルの形式 / Reference file format</a></li>
</ul>
<p><small>main · {html.escape(revision)}</small></p></html>''')
    (output / ".nojekyll").touch()
    print(f"公開用の文書 / Documentation site: {output}")


if __name__ == "__main__":
    main()
