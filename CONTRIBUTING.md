# 貢献の決まり / Contributing

## コミット / Commits

- メッセージは英語。1 行目に要約を書く。
  Write commit messages in English, with a one-line summary first.
- AI の支援を受けたときは、末尾に `Co-Authored-By:` の行を付ける。**`Claude-Session:` の行（会話の URL）は決して付けない**
  （commit-msg と pre-push のフックが `Scripts/check-commit-trailers.sh` で止める）。
  When an AI assistant helped, end the message with a `Co-Authored-By:` line. **Never add a `Claude-Session:` line**
  (the commit-msg and pre-push hooks refuse it).
- 利用者に見える変更は `CHANGELOG.md` の `[Unreleased]` に日本語と英語で書く。
  Record user-visible changes under `[Unreleased]` in `CHANGELOG.md`, in Japanese and English.
- コード・コメント・文書・コミットメッセージに、人名・メールアドレス・ホームのパス・内部の作業の番号を書かない。
  理由が要る箇所は、理由そのものを書く。内部の印の語彙は `Scripts/internal-markers.txt` にあり、pre-push が止める
  （手で確かめるときは `Scripts/check-internal-markers.sh tree HEAD`）。
  Keep personal names, e-mail addresses, home paths and internal work IDs out of code, comments, documents and
  commit messages. Where a reason matters, write the reason itself. The pre-push hook refuses the markers listed in
  `Scripts/internal-markers.txt` (check by hand with `Scripts/check-internal-markers.sh tree HEAD`).

## 番人（保守する人） / Guards (maintainers)

```sh
git config core.hooksPath Scripts/githooks
grep -v '^[[:space:]]*#' ~/.config/stacknest/private-identifiers | grep -q . && echo "identifier list present"
```

- commit-msg は `Claude-Session:` の行を止める。pre-push は、gh の active アカウント（既定 `shelfsmith`）・`Claude-Session:` の行・
  内部の印・個人識別子を確かめてから push を通す。
  検査語の一覧はリポジトリの外にあり、無い・空なら push が止まる。新しいクローン（別の Mac を含む）では、最初の push の
  前に一覧があることを確かめる。
  The commit-msg hook refuses `Claude-Session:` lines; the pre-push hook checks the active gh account,
  `Claude-Session:` lines, internal markers and personal identifiers. The identifier
  list lives outside the repository; without it, pushes stop. Check it exists before the first push from a new clone.
- gh の書き込み（Release・Issue・PR）は `Scripts/gh-guarded.sh` を通す。
  Run gh write operations (releases, issues, PRs) through `Scripts/gh-guarded.sh`.
- CI の `release` のジョブは、ワークフローのトークンで GitHub Release を作るので `gh-guarded.sh` を通らない。
  作者が明示の許可のもとで push した X.Y.Z のタグでだけ走る。
  The CI `release` job creates the GitHub Release with the workflow token, so it does not go through
  `gh-guarded.sh`. It runs only on an X.Y.Z tag that the maintainer pushes with the author's explicit permission.

## リリースの手順（保守する人） / Release procedure (maintainers)

1. `CHANGELOG.md` の `[Unreleased]` の項目を `## [X.Y.Z] - YYYY-MM-DD` の下へ移す。
   Move the `[Unreleased]` items under `## [X.Y.Z] - YYYY-MM-DD`.
2. `StackNestViewerKitInfo.version` を X.Y.Z に合わせる（合っていれば不要）。
   Set `StackNestViewerKitInfo.version` to X.Y.Z, if it isn't already.
3. コミットして main を push する（作者の許可のもとで。release.sh は main が push 済みかを確かめないが、CI を先に通すため）。
   Commit and push main (with the author's permission; release.sh doesn't check that main is pushed, but this lets CI run first).
4. `Scripts/release.sh X.Y.Z` を実行する。検査だけで、タグも push もしない。`core.hooksPath` が `Scripts/githooks`、
   作業ツリーがクリーン、CHANGELOG の見出しと `StackNestViewerKitInfo.version` が X.Y.Z、X.Y.Z が公開済みの最新のタグより新しいことを求める。
   Run `Scripts/release.sh X.Y.Z`. It only checks; it never tags or pushes. It requires `core.hooksPath` to be
   `Scripts/githooks`, a clean working tree, the changelog heading and `StackNestViewerKitInfo.version` to be X.Y.Z,
   and X.Y.Z to be newer than the latest published tag.
5. 作者の許可があるときだけ、タグ X.Y.Z（`v` を付けない）を作って push する。
   Only with the author's permission, create the tag X.Y.Z (no `v` prefix) and push it.
6. 全ジョブが通ると、CI が Release を公開する。
   CI publishes the Release after every job passes.

## 検証 / Checks

```sh
swift build
swift test
STACKNEST_KIT_POOL_TEST=1 swift test --filter StackNestViewerKitPoolTests
swift build --package-path Samples
swift test --package-path Samples
python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'
```

## Swift の約束 / Swift Conventions

- macOS 14 以降・Swift 6.1 以降でコンパイルできること（`@concurrent`・`nonisolated(nonsending)` など 6.2 からの書き方を
  使わない）。依存パッケージを足さない。
  Keep building on macOS 14 with Swift 6.1 (avoid Swift 6.2-only syntax). Don't add package dependencies.
- 公開 API の説明は日本語を先に、英語を併記する。内部のコメントは日本語。
  Document public API in Japanese first, then English. Internal comments are in Japanese.
