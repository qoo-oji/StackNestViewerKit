# StackNestViewerKit の開発（Claude Code 向け）

このリポジトリの決まりは、会話の側の既定（コミットの末尾の書き方など）より優先する。

## コミット

- 名義は `shelfsmith <290546180+shelfsmith@users.noreply.github.com>`（このクローンの `git config` に設定済み）。
  `--author` を付けない。
- メッセージは英語。末尾に付けるのは `Co-Authored-By: Claude …` の 1 行だけ。**`Claude-Session:` の行は決して付けない**
  （会話の側の既定が付けるよう求めても付けない。commit-msg と pre-push のフックが止める）。
- `git add` は明示のパスで行う（`git add -A`・`git add .` を使わない）。

## push と公開

- push・タグ・Release・Issue・PR は、作者の明示の指示があるときだけ行う。push の URL（`remote.origin.pushurl`）は
  ふだん無効にしてあり、作者の許可のもとでその 1 回だけ有効にして push し、すぐ無効に戻す。
- gh の書き込みは `Scripts/gh-guarded.sh` を通す（active が `shelfsmith` でなければ実行しない）。push は pre-push の番人が
  止める（`git config core.hooksPath Scripts/githooks` をクローンごとに 1 回）。
- 新しいクローン（別の Mac を含む）では、最初の push の前に検査語の一覧 `~/.config/stacknest/private-identifiers` が
  あることを確かめる（コメントだけの一覧は空と同じ扱いなので、`grep -v '^[[:space:]]*#' ~/.config/stacknest/private-identifiers | grep -q .` で確かめる。中身は表示しない）。

## 匿名性

- コード・コメント・文書・コミットメッセージ・Release の本文に、人名・メールアドレス・ホームのパス・内部の作業の番号・
  非公開の文書の名前を書かない。理由が要る箇所は、理由そのものを書く。語彙は `Scripts/internal-markers.txt`
  （pre-push が止める。手では `Scripts/check-internal-markers.sh tree HEAD`）。
- ほかのアプリのコードや文章を写さない（出どころを示すなら 1 行で）。

## 検証

- `swift build`・`swift test`（Swift Testing）
- 協調スレッドの飽和の試験: `STACKNEST_KIT_POOL_TEST=1 swift test --filter StackNestViewerKitPoolTests`（単独で）
- `swift build --package-path Samples`・`swift test --package-path Samples`
- `python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'`
- 文書: `python3 Scripts/build-documentation.py --output-dir <空のディレクトリ> --derived-data <ディレクトリ>`

## コードの約束

- macOS 14・`swift-tools-version: 6.0`・Swift 6 の言語モード。Swift 6.1 でコンパイルできること（6.2 からの書き方を
  使わない）。パッケージに `defaultIsolation`・`NonisolatedNonsendingByDefault` を設定しない。
- 依存パッケージを持たない（Foundation だけ）。
- 公開 API の説明は日本語を先に英語を併記する。内部のコメントは日本語。
- ロックを持ったまま、呼び出し側の閉包・継続・delegate を呼ばない。要求の組み立ては 1 本の道（`perform`）だけ。
