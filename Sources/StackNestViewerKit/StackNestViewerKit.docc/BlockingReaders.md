# 同期の読み手 / Blocking Readers

同期の読み出し API（書庫の読み手など）を持つビューアのための橋渡し。

A bridge for viewers with a synchronous reading API, such as archive readers.

## 呼ぶスレッド / Where to Call It

``StackNestBlockingReader`` は応答が返るまで呼んだスレッドをふさぐ。**ブロックしてよいスレッド**（ホストが
I/O のために用意したスレッドやキュー）からだけ呼ぶ。メインスレッドや `Task` の中（協調スレッド）から呼ぶと、
Debug では `assertionFailure` で知らせる（完全な検出ではない）。橋渡しは `Task` を作らず `await` もしないので、
協調スレッドがふさがっていても進む。

``StackNestBlockingReader`` blocks the calling thread until the response arrives. Call it only from a thread the
host lets block. Calls from the main thread or inside a `Task` trigger `assertionFailure` in debug builds (the
detection isn't exhaustive). The bridge never creates a `Task` or awaits, so it keeps working when the cooperative
pool is saturated.

```swift
import Foundation
import StackNestViewerKit

/// ホストの取り消しの旗（借りたスレッドでは Task.isCancelled が使えない）。
final class HostCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// 書庫の読み手の形（エントリの名前でページを読む）。
struct StackNestArchiveReader {
    let reader: StackNestBlockingReader

    init(session: StackNestBookSession, cancellation: HostCancellation) {
        reader = StackNestBlockingReader(session: session, isCancelled: { cancellation.isCancelled })
    }

    func entryNames() throws -> [String] {
        StackNestPageNaming.entryNames(pageCount: try reader.manifest().pageCount)
    }

    func data(atEntry name: String) throws -> Data {
        guard let index = StackNestPageNaming.pageIndex(fromEntryName: name) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try reader.page(index).data
    }
}
```

## 取り消しと時間切れ / Cancellation and Timeouts

要求を出す前に `isCancelled` を見て、立っていれば要求を出さずに `CancellationError` を投げる。待つ間も 0.1 秒ごとに
見る。`waitLimit`（既定 25 秒）は**要求ごと**に数え、超えた要求は `cannotConnect` で戻る（async の顔も同じ）。
`page(_:)` は 1 回の呼び出しで最大 3 件の要求（範囲の確かめ・ページ・404 の後の manifest の読み直し）を出しうるので、
最悪で `waitLimit` の 3 倍まで待ってから戻る。負の番号と、既知のページ数の範囲外と分かった番号は `pageOutOfRange`
（ホストは自分の「エントリが無い」に読み替える）。閉じた後は番号に関わらず `CancellationError`。

`isCancelled` is checked before a request is made and every 0.1 seconds while waiting. `waitLimit` (25 seconds by
default) is counted **per request**; a request that exceeds it fails with `cannotConnect` (the async calls behave
the same). One `page(_:)` call can make up to three requests (the range check, the page, and a manifest re-read
after a 404), so in the worst case it waits up to three times `waitLimit` before returning. Negative numbers and
numbers found to be outside the known page count fail with `pageOutOfRange` (map it to the host's own "no such
entry"). After `close()`, calls fail with `CancellationError` whatever the number.
