# 始め方 / Getting Started

参照ファイルを開き、ページを表示し、読書位置を書き戻し、閉じるまで。

Open a reference file, show pages, write the reading position back and close.

## 導入 / Installation

部品は Swift 6.1 以降・macOS 14 以降が要る。`Package.swift` の依存に部品を足す。0.x の間は minor の版で壊す変更が
ありうるので、次の minor までにとどめる。

The kit needs Swift 6.1 or later and macOS 14 or later. Add the package. While the version is 0.x, a minor release
can break the API, so stay within one minor version.

```
.package(url: "https://github.com/shelfsmith/StackNestViewerKit", .upToNextMinor(from: "0.1.0"))
```

ビューアのターゲットは `StackNestViewerKit`、試験のターゲットは `StackNestViewerKitTesting` に依存する。

Depend on `StackNestViewerKit` from the app target and on `StackNestViewerKitTesting` from the test target.

## 統合の例 / Integration Example

次の例は README・試験（`IntegrationExample.swift`）・ホストの設定の組み合わせの確認（`Samples/Sources/HostMode*`）と
同じコードで、どれも同じであることを文書のビルドが確かめる。

This example is the same code as in the README, the tests and the host-mode checks; the documentation build
verifies they match.

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

- 参照ファイルの読み取りは同期。応答しないボリュームの上にありうるなら、ブロックしてよいスレッドでセッションを作る。
- `manifest()` を最初に呼ぶ（StackNest が読み込みに気づく）。
- `page(_:)`・`note(page:)` の番号は **StackNest のページ番号**。ビューアが除外・並べ替えをしても、自分の並びの位置を渡さない。

- Reading the reference file is synchronous; create the session on a thread that may block if the file could be on an unresponsive volume.
- Call `manifest()` first so StackNest notices the open.
- Numbers passed to `page(_:)` and `note(page:)` are **StackNest page numbers**, not positions in the viewer's own (filtered or sorted) list.
