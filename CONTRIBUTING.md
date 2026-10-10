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
