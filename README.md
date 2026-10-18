# StackNestViewerKit

外部ビューアが StackNest の本を読み、読書位置を StackNest へ書き戻すための Swift パッケージ。

A Swift package for external viewers to read StackNest books and write the reading position back to StackNest.

## 概要 / Overview

[StackNest](https://github.com/shelfsmith/stacknest) は Mac の画像の本のライブラリ管理アプリ。対応したビューアへ、本の
ファイルの代わりに参照ファイル（`.stacknestbook`）を渡す。ビューアは参照ファイルに書かれた 127.0.0.1 の API から
ページを 1 枚ずつ取り、読み進めたページを書き戻す。この部品は、その約束（形式・宣言・名乗り・状態コード・鍵の扱い）を
1 か所で実装し、ビューアの差し込みを数十行にする。

- `StackNestViewerKitCore`: 参照ファイルの型・宣言の解釈・名乗り・エラーと英日の文言（通信を持たない）
- `StackNestViewerKit`: 本のセッション（async と同期）・先読み・読書位置の書き戻し（Core を再輸出する）
- `StackNestViewerKitTesting`: ビューアの試験のための `URLProtocol` の見立てとサンプル

依存パッケージは無い（Foundation だけ）。形式の文書は [Documentation/BookReferenceFormat.md](Documentation/BookReferenceFormat.md)
（[English](Documentation/BookReferenceFormat.en.md)）。

[StackNest](https://github.com/shelfsmith/stacknest) is an image book library manager for the Mac. It hands a
supporting viewer a reference file (`.stacknestbook`) instead of the book's file; the viewer fetches pages one at a
time from the API on 127.0.0.1 named in the file and writes the reading position back. This kit implements that
contract (format, declaration, identification, status codes, token handling) in one place, so integrating takes a
few dozen lines. It has no dependencies beyond Foundation. The format is documented in
[Documentation/BookReferenceFormat.en.md](Documentation/BookReferenceFormat.en.md).

## すぐに試す / Quick Start

StackNest を入れていなくても、手元の偽の StackNest で試せる。

You can try it without StackNest, using a local fake server.

Samples パッケージ（このクイックスタートと端から端の試験）は Swift 6.2（Xcode 26）以降が要る。部品そのものは Swift 6.1 から。
The Samples package (this quick start and the end-to-end tests) needs Swift 6.2 (Xcode 26) or later; the kit itself
builds with Swift 6.1 or later.

```sh
swift run --package-path Samples stacknest-fake-server \
    --folder ~/Pictures/SomeBook --reference-out /tmp/Book.stacknestbook --record-out /tmp/requests.json
# 別の端末で / in another terminal:
swift run --package-path Samples stacknest-kit-probe /tmp/Book.stacknestbook
```

`stacknest-kit-probe` は manifest → 開くページ → progress を試して結果を JSON で出す（鍵は出さない）。
`--no-progress` を付けると書き戻さない（実物の StackNest に向けるときに使う。読書位置の記録を動かさない）。
偽の StackNest は受けた要求を `--record-out` に書く。

`stacknest-kit-probe` tries manifest, the start page and progress and prints JSON (never the token). Add
`--no-progress` to skip writing back (use it against a real StackNest so the reading position record doesn't move).
The fake server records the requests it receives.

## 導入 / Installation

```swift
.package(url: "https://github.com/shelfsmith/StackNestViewerKit", .upToNextMinor(from: "0.2.0"))
```

アプリのターゲットは `StackNestViewerKit`、試験のターゲットは `StackNestViewerKitTesting` に依存する（`StackNestStubServer` の `configuration()` で作ったセッションは
見立てを生かしておくので、セッションだけを返す補助でもよい）。0.x の間は
minor の版で壊す変更がありうるので、次の minor までにとどめる。

Depend on `StackNestViewerKit` from the app and `StackNestViewerKitTesting` from tests (a session built from
`StackNestStubServer`'s `configuration()` keeps the stub alive, so a helper may return only the session). While the version is 0.x a
minor release can break the API, so stay within one minor version.

## 統合の手引き / Integration Guide

1. **宣言と型 / Declaration and type**: `Info.plist` に `StackNestViewerSupport`（`referenceFormatVersions = [1]`）を置き、
   `app.shelfsmith.stacknest.book-reference` を取り込んで書類として受け付ける。試験に
   `StackNestViewerSupport.verify(infoDictionary:)` の自己点検を 1 つ置く。
   Declare `StackNestViewerSupport`, import the type and accept it as a document; add the self-check to your tests.
2. **通信の許可 / Network access**: `NSAllowsLocalNetworking` と外への接続（client）の権限。部品は既定で `127.0.0.1` と
   `::1` にしかつながない（`allowedHosts` で明示して広げる）。
   Allow local networking and the outgoing network entitlement. The kit connects only to `127.0.0.1` and `::1` unless
   you widen `allowedHosts`.
3. **開く / Open**: `StackNestBookSession(contentsOf:)` は参照ファイルを同期に読む。応答しないボリュームの上にありうる
   なら、ブロックしてよいスレッドで作る。最初に `manifest()` を読む。
   `StackNestBookSession(contentsOf:)` reads the file synchronously; if it could be on an unresponsive volume, create
   the session on a thread that may block. Read `manifest()` first.
4. **ページ / Pages**: `page(_:)` の番号は StackNest のページ番号（ビューアの一覧の位置ではない）。`contentType` で形式を見る。
   The number passed to `page(_:)` is StackNest's page number (not a position in your own list); check `contentType`
   for the format.
5. **先読み / Prefetch**: `prefetch(_:)` には読む向きの近いページから渡す。
   Pass pages nearest in reading direction first.
6. **解読の枠 / Decoding slots**: バイト列を取り終えてから解読の枠を取る。先読みの取り中のページに表示の要求が
   乗ったら、枠の列でも表示の側へ並べ直す。
   Take a decoding slot after the bytes arrive, and promote joined display requests in your slot queue.
7. **書き戻し / Progress**: `StackNestProgressReporter` に `note(page:)` を渡し、閉じるときに `close()`。`close()` の後
   （と、終了時の `StackNestProgressRegistry.shared.flushAllBlocking(timeout:)` が報告者を閉じた後）の
   `note(page:)` は無視される。終了時は `applicationShouldTerminate` から `flushAllBlocking(timeout:)` を呼んで
   `.terminateNow` を返す（例は DocC の「Writing Progress」）。`flushAll(timeout:completion:)` と `.terminateLater` の
   組み合わせは、終了がメインキューの仕事の中から求められると止まったままになるので使わない。送り切りは未送信のあった
   報告者を閉じる。別の処理が終了を取り消したら、閉じた報告者は閉じたままなので、まだ開いている本の報告者を作り直す。
   Pass `note(page:)` to a `StackNestProgressReporter` and call `close()` when done; `note(page:)` after `close()` (or
   after the quit-time flush has closed the reporter) is ignored. At quit, call
   `StackNestProgressRegistry.shared.flushAllBlocking(timeout:)` from `applicationShouldTerminate` and return
   `.terminateNow` (see "Writing Progress" in the DocC) so the last position is not lost. Don't pair
   `flushAll(timeout:completion:)` with `.terminateLater`: it hangs when termination is requested from inside a
   main-queue job. The flush closes the reporters that had unsent work. If another quit handler vetoes the quit, those
   reporters stay closed, so create new reporters for the books that are still open.
8. **同期の読み手 / Blocking readers**: 同期の API を持つビューアは、ブロックしてよいスレッドから
   `StackNestBlockingReader` を呼ぶ（メインスレッドや協調スレッドからは呼ばない）。
   If your viewer has a blocking API, call `StackNestBlockingReader` only from a thread that may block (never the main
   thread or the cooperative pool).
9. **エラー / Errors**: `switch error.code { … default: … }` で受け、残りは `error.message()` の英日の文言に任せる。
   Catch with `switch error.code { … default: … }` (the code is an open set) and leave the rest to the English and
   Japanese text of `error.message()`.
10. **ライブラリの機能（推奨） / Library features (recommended)**: 鍵を保存しない。本の同一性は参照ファイルのパスで取る（`book`
    の URL は開くたびに変わることがある）。参照ファイルの本はコレクション・書き出し・メタデータに入れない（期限が
    切れると読めなくなり、StackNest が参照ファイルを消す）。
    Never store the token; identify the book by the reference file's path; keep reference books out of collections,
    exports and metadata.

### 統合の例 / Integration Example

<!-- integration-example:begin -->
```swift
import Foundation
import StackNestViewerKit

/// 開いた StackNest の本（ビューアが持っておくもの）。
struct OpenedStackNestBook {
    let session: StackNestBookSession
    let reporter: StackNestProgressReporter
    let pageCount: Int
    let startPage: Int
}

/// StackNest の参照ファイルを開く。Info.plist には StackNestViewerSupport（referenceFormatVersions = [1]）・
/// 参照ファイルの型の取り込み・127.0.0.1 への平文の HTTP（NSAllowsLocalNetworking）・外への接続の許可が要る。
@MainActor
func openStackNestBook(
    at url: URL, configuration: StackNestBookSession.Configuration = .init(),
    showNotice: @escaping @MainActor (String) -> Void
) async throws -> OpenedStackNestBook {
    // 参照ファイル（数百バイト）は同期に読む。応答しないボリュームの上にありうるなら、ブロックしてよいスレッドで作る。
    // 既定では 127.0.0.1 と ::1 にしかつながない。
    let session = try StackNestBookSession(contentsOf: url, configuration: configuration)
    let manifest = try await session.manifest()  // 最初に読む（StackNest が読み込みに気づく）
    let start = StackNestBookReference.clampedStartPage(session.reference.startPage, pageCount: manifest.pageCount)
    let reporter = StackNestProgressReporter(session: session, startPage: start) { error in
        showNotice(error.message())  // 既定の英日の文言
    }
    return OpenedStackNestBook(session: session, reporter: reporter, pageCount: manifest.pageCount, startPage: start)
}

/// ページを表示する（`page` は StackNest のページ番号）。
@MainActor
func showPage(_ page: Int, of book: OpenedStackNestBook) async throws -> StackNestPage {
    let result = try await book.session.page(page)
    book.reporter.note(page: page)
    book.session.prefetch([page + 1, page + 2])  // 読む向きの近い順に
    return result
}

/// 閉じる。
@MainActor
func closeStackNestBook(_ book: OpenedStackNestBook) {
    book.reporter.close()
    book.session.close()
}
```
<!-- integration-example:end -->

このコードは試験（`Tests/StackNestViewerKitPublicAPITests/IntegrationExample.swift`）と、ホストの設定の組み合わせの
確認（`Samples/Sources/HostMode*`）でも同じものをコンパイルしている。

The same code is compiled by the tests and by the host-mode checks in `Samples`.

## セキュリティ / Security

- つなぐのは既定で `127.0.0.1` と `::1` だけ。リダイレクトには付いて行かず、鍵は `book` の宛先にだけ送る。
- 要求を出すのは、`book` のパスが StackNest の書く形（`/api/v1/libraries/…/books/…`・`/api/v1/relay/…`）のときだけ
  （127.0.0.1 の別のサービスへ鍵を送らない。`allowsAnyBookPath` で外せる）。
- プロキシは使わない（システムや PAC のプロキシは無効にする）ので、鍵がプロキシへ渡ることはない。
- 鍵はメモリの中だけ。`StackNestBookReference` は `Codable` ではなく、説明・`dump` では伏せる。
- 本文は 64 MiB まで、期限は要求のたびに確かめ、`URLSession` はキャッシュ・クッキー・資格情報の保管を持たない。
- `waitLimit`（既定 25 秒）は要求ごとに数える。async の顔も同期の顔も、1 回の呼び出しは要求を最大 3 件（範囲の確かめ・
  ページ・404 の後の読み直し）出しうるので、最悪で `waitLimit` の 3 倍まで待ってから `.cannotConnect` で戻る。
- 名乗り（`X-StackNest-Viewer`）は StackNest の読み方と同じ厳しさで読む（bundle id は 64 文字まで・使える文字は限る。
  不正な `kit=` は捨てる）。送る値も同じ規則に整える。
- 参照ファイルを断る規則は形式の文書にある（[日本語](Documentation/BookReferenceFormat.md)・
  [English](Documentation/BookReferenceFormat.en.md)）。

- Connects only to `127.0.0.1` and `::1` by default; refuses redirects; sends the token only to the `book` origin.
- Makes requests only when the `book` path has a shape StackNest writes (`/api/v1/libraries/…/books/…` or
  `/api/v1/relay/…`), so the token never goes to another service on 127.0.0.1 (`allowsAnyBookPath` turns this off).
- Never uses a proxy (system and PAC proxies are disabled), so the token can't reach one.
- Keeps the token in memory only; `StackNestBookReference` isn't `Codable` and redacts the token.
- Caps bodies at 64 MiB, checks expiry before every request, and uses no cache, cookie or credential storage.
- `waitLimit` (25 seconds by default) is counted per request. A single async or blocking call can make up to three
  requests (range check, the page, a manifest re-read after a 404), so in the worst case it waits up to three times
  `waitLimit` before returning `.cannotConnect`.
- The identification header (`X-StackNest-Viewer`) is parsed as strictly as StackNest does (bundle id up to 64
  characters from a limited character set; an invalid `kit=` is dropped); the value the kit sends is reduced to the same rules.
- The rules for refusing a reference file are in the format document
  ([English](Documentation/BookReferenceFormat.en.md)).

## 動作環境 / Requirements

- macOS 14 以降 / macOS 14 or later (arm64・x86_64)
- Swift 6.1 以降（`swift-tools-version: 6.0`・Swift 6 の言語モード）。CI は Swift 6.1 から確かめる。
- Swift 6.1 or later (`swift-tools-version: 6.0`, Swift 6 language mode); CI checks from Swift 6.1.
- Samples パッケージ（すぐに試す・端から端の試験）は Swift 6.2（Xcode 26）以降。
  The Samples package (quick start, end-to-end tests) needs Swift 6.2 (Xcode 26) or later.

## 版の方針 / Versioning

semver。0.x の間は壊す変更で minor を上げる。読める参照ファイルの版を足すのは minor、落とすのは major。変更は
[CHANGELOG.md](CHANGELOG.md)。部品の版（semver）と参照ファイルの版（整数）は別の軸。

Semantic versioning; while 0.x, breaking changes bump the minor version. Adding a readable reference version is a
minor change and dropping one is major. See [CHANGELOG.md](CHANGELOG.md).

公開の enum（`StackNestReadingDirection`・`StackNestLanguage`・`StackNestRequestPriority`・`StackNestViewerSupport.Issue`、
Testing の `Route`・`Response`）は、0.x の minor でケースが増えることがある。`switch` には `default` を書く。

Public enums (`StackNestReadingDirection`, `StackNestLanguage`, `StackNestRequestPriority`,
`StackNestViewerSupport.Issue`, and the Testing target's `Route` and `Response`) may gain cases in a 0.x minor
version, so always switch with a `default` case.

## 開発 / Development

```sh
swift build
swift test
STACKNEST_KIT_POOL_TEST=1 swift test --filter StackNestViewerKitPoolTests   # 協調スレッドを飽和させる試験（単独で）
swift test --package-path Samples                                            # 偽の StackNest を相手にした端から端
python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'                  # スクリプトの試験
python3 Scripts/build-documentation.py --output-dir "$(mktemp -d)/site" --derived-data .build/documentation/DerivedData
```

協調スレッドを飽和させる試験は、同じプロセスのほかの試験を止めるので、ふだんの `swift test` では skip し、単独で走らせる。

The pool-saturation test stalls other tests in the same process, so it is skipped by plain `swift test` and runs on
its own.

保守する人は、新しいクローン（別の Mac を含む）ごとにフックを有効にし、最初の push の前に検査語の一覧があることを確かめる
（無い・空なら push が止まる）。

Maintainers enable the hooks in every new clone and check the identifier list exists before the first push.

```sh
git config core.hooksPath Scripts/githooks
grep -v '^[[:space:]]*#' ~/.config/stacknest/private-identifiers | grep -q . && echo "identifier list present"
```

番人は失敗したら通さない側に倒れる。pre-push は、push する先端のファイル全体と、push 先にまだ無いコミットの足した行・メッセージ・
作成者を検査し、push する ref の名前と注釈付きタグのメッセージも検査する。`Scripts/gh-guarded.sh` は、会話の URL や内部の印を含む投稿を断る。

The guards fail closed. The pre-push hook scans the whole tree at the pushed tip plus the added lines, messages and authors of
the commits not yet on the push target, and also the pushed ref names and annotated tag messages; `Scripts/gh-guarded.sh` refuses posts that contain session URLs or internal
markers.

## 貢献の決まり / Contributing

- コミットの末尾に付けるのは `Co-Authored-By:` の行だけ。`Claude-Session:` の行（会話の URL）は付けない（フックが止める）。
  End commits with `Co-Authored-By:` only; never add a `Claude-Session:` line (the hooks refuse it).
- コード・文書・コミットに、人名・ホームのパス・内部の作業の番号を書かない（内部の印は `Scripts/internal-markers.txt`、人名などは
  リポジトリの外の検査語の一覧で、pre-push が止める）。
  Keep personal names, home paths and internal work IDs out of code, docs and commits.
- 利用者に見える変更は `CHANGELOG.md` の `[Unreleased]` に日英で書く。詳しくは [CONTRIBUTING.md](CONTRIBUTING.md)。
  Record user-visible changes under `[Unreleased]` in Japanese and English. See [CONTRIBUTING.md](CONTRIBUTING.md).

## ライセンス / License

MIT（[LICENSE](LICENSE)）。
