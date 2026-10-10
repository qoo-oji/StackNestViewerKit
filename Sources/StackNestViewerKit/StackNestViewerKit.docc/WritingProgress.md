# 読書位置の書き戻し / Writing Progress

``StackNestProgressReporter`` と、終了時の送り切り。

``StackNestProgressReporter`` and flushing at quit.

## まとめて送る / Batching

`note(page:)` のたびに 3 秒待ち直し、最初に止まってから 10 秒を超えては待たない。飛ぶ送信は 1 件で、待つのは最新の
1 件。失敗したページはすぐには送り直さず、次の `note(page:)`・`flush()`・`close()` で送る。期限切れ・認証失敗・本が
無い・ライブラリのロック・つないでよくないホストの後は、その本については送らない。同じ種類の知らせは続けて 1 度だけ
（送れたら記憶を消す）。閉じるときは ``StackNestProgressReporter/close()``。`close()` の後（と、終了時の
``StackNestProgressRegistry/flushAll(timeout:completion:)`` が報告者を閉じた後）の `note(page:)` は無視される。

Each `note(page:)` restarts a 3-second wait, never longer than 10 seconds from the first change. One send is in
flight and only the newest page waits. A failed page isn't retried on its own; it goes out with the next
`note(page:)`, `flush()` or `close()`. After a permanent failure (expired, unauthorized, book not found, library
locked, host not allowed) nothing more is sent for that book. The same kind of failure is reported once in a row
(a successful send resets that). Call ``StackNestProgressReporter/close()`` when the book closes; `note(page:)`
after `close()` (or after the quit-time ``StackNestProgressRegistry/flushAll(timeout:completion:)`` has closed the
reporter) is ignored.

## 終了時 / At Quit

⌘Q は「閉じた」を通らないので、``StackNestProgressRegistry`` で送り切る。

⌘Q doesn't go through closing, so flush with ``StackNestProgressRegistry``.

```swift
import AppKit
import StackNestViewerKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let registry = StackNestProgressRegistry.shared
        if registry.isFlushing { return .terminateLater }  // 先の待ちが応答を返す
        guard registry.hasUnsentWork else { return .terminateNow }
        registry.flushAll(timeout: .seconds(2)) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
```

記録を残さない窓（シークレットウインドウなど）で書き戻すかは、ホストが役を作るかどうかで決める。

Whether a private window writes progress back is the host's choice: don't create a reporter for it.
