# 読書位置の書き戻し / Writing Progress

``StackNestProgressReporter`` と、終了時の送り切り。

``StackNestProgressReporter`` and flushing at quit.

## まとめて送る / Batching

`note(page:)` のたびに 3 秒待ち直し、最初に止まってから 10 秒を超えては待たない。飛ぶ送信は 1 件で、待つのは最新の
1 件。失敗したページはすぐには送り直さず、次の `note(page:)`・`flush()`・`close()` を待つ（その間に新しいページが来れば、新しい方を送る）。期限切れ・認証失敗・本が
無い・ライブラリのロック・つないでよくないホストの後は、その本については送らない。同じ種類の知らせは続けて 1 度だけ
（送れたら記憶を消す）。閉じるときは ``StackNestProgressReporter/close()``。`close()` の後（と、終了時の
``StackNestProgressRegistry/flushAllBlocking(timeout:)`` が報告者を閉じた後）の `note(page:)` は無視される。

Each `note(page:)` restarts a 3-second wait, never longer than 10 seconds from the first change. One send is in
flight and only the newest page waits. A failed page isn't retried on its own; it waits for the next
`note(page:)`, `flush()` or `close()`, and a newer page noted in the meantime replaces it (after the batching wait). After a permanent failure (expired, unauthorized, book not found, library
locked, host not allowed) nothing more is sent for that book. The same kind of failure is reported once in a row
(a successful send resets that). Call ``StackNestProgressReporter/close()`` when the book closes; `note(page:)`
after `close()` (or after the quit-time ``StackNestProgressRegistry/flushAllBlocking(timeout:)`` has closed the
reporter) is ignored.

`flushAllBlocking`（と `flushAll`）は、未送信のあった報告者を閉じる。その後に別の処理が終了を取り消すと、閉じた報告者は
閉じたままで、その後の `note(page:)` は無視される。どれが閉じたかは分からないので、まだ開いている本の報告者を作り直すこと。

`flushAllBlocking` (and `flushAll`) closes the reporters that had unsent work. If another quit handler then vetoes the
quit, those reporters stay closed and later `note(page:)` calls on them are ignored. You can't tell which ones were
closed, so create new reporters for the books that are still open.

## 終了時 / At Quit

⌘Q は「閉じた」を通らないので、``StackNestProgressRegistry`` で送り切る。
``StackNestProgressRegistry/flushAllBlocking(timeout:)`` は、送信をメインスレッドの外で走らせ、送り切るか上限が来るまで
メインスレッドで待つ。送るものが無ければすぐ戻る。

⌘Q doesn't go through closing, so flush with ``StackNestProgressRegistry``.
``StackNestProgressRegistry/flushAllBlocking(timeout:)`` runs the sends off the main thread and waits on the main
thread until they finish or the limit passes. It returns at once when there is nothing to send.

```swift
import AppKit
import StackNestViewerKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        StackNestProgressRegistry.shared.flushAllBlocking(timeout: .seconds(2))
        return .terminateNow
    }
}
```

`.terminateLater` を返して ``StackNestProgressRegistry/flushAll(timeout:completion:)`` の `completion` から
`reply(toApplicationShouldTerminate:)` を呼ぶ形は使わない。終了がメインキューの仕事の中から求められると
（`DispatchQueue.main.async` や `Task { @MainActor in }` の中の `NSApp.terminate(nil)`。スライドショーの終わりの動作や
自動操作の口など）、AppKit はその仕事の中で応答を待つ入れ子の run loop を回す。メインキューは入れ子では回らないので、
送り終えたかの確かめも `completion` も上限のタイマーも走らず、アプリは終わらないまま止まる。

Don't return `.terminateLater` and call `reply(toApplicationShouldTerminate:)` from the `completion` of
``StackNestProgressRegistry/flushAll(timeout:completion:)``. When termination is requested from inside a main-queue job
(`NSApp.terminate(nil)` inside `DispatchQueue.main.async` or `Task { @MainActor in }` — a slideshow's end action or an
automation hook, for example), AppKit waits for the reply in a nested run loop inside that job. The main queue isn't
drained re-entrantly, so the check that the sends finished, `completion` and the limit's timer never run, and the app
hangs without quitting.

## 試験と登録簿 / Tests and Registries

役を作る形のうち `registry:` を取らないものは、``StackNestProgressRegistry/shared`` に役を載せる。ホストの試験は、
自分の登録簿（``StackNestProgressRegistry/init()``）を作って渡すと、プロセスで 1 つの登録簿に役を残さない（残すと、
同じプロセスのアプリの終了の処理がその役の送り切りを待つ）。

The initializers without `registry:` put the reporter in ``StackNestProgressRegistry/shared``. Host tests can pass
a registry of their own (``StackNestProgressRegistry/init()``) so their reporters don't stay in the process-wide one
(where the app's quit handler in the same process would wait to flush them).

```swift
import StackNestViewerKit

@MainActor
func makeTestReporter(session: StackNestBookSession) -> (StackNestProgressReporter, StackNestProgressRegistry) {
    let registry = StackNestProgressRegistry()
    let reporter = StackNestProgressReporter(session: session, startPage: 0, registry: registry) { _ in }
    return (reporter, registry)
}
```

記録を残さない窓（シークレットウインドウなど）で書き戻すかは、ホストが役を作るかどうかで決める。

Whether a private window writes progress back is the host's choice: don't create a reporter for it.
