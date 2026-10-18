import Foundation

/// 開いている書き戻しの役を覚えておき、アプリの終了時にまとめて送り切る（⌘Q は「閉じた」を通らないため）。
/// 持つのは弱い参照だけ。AppKit への差し込み（`applicationShouldTerminate`）はホストに残す:
///
///     func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
///         StackNestProgressRegistry.shared.flushAllBlocking(timeout: .seconds(2))
///         return .terminateNow
///     }
///
/// Remembers open reporters (weakly) and flushes them all when the app quits. Call
/// ``flushAllBlocking(timeout:)`` from `applicationShouldTerminate` and return `.terminateNow`, as above.
@MainActor
public final class StackNestProgressRegistry {
    /// アプリで 1 つの登録簿。 / The app-wide registry.
    public static let shared = StackNestProgressRegistry()

    private struct Entry { weak var reporter: StackNestProgressReporter? }
    private var entries: [Entry] = []

    /// 送り切りの途中か（終了がもう一度求められたら、先の待ちの応答に任せる）。
    ///
    /// Whether a flush is in progress (a second quit request should wait for it).
    public private(set) var isFlushing = false

    /// `shared` とは別の登録簿を作る。ホストの試験が、役をプロセスで 1 つの `shared` に載せないために使う
    /// （役を作るときに `registry:` で渡す）。アプリの終了時に送り切るのは、ふつうは `shared` だけ
    /// （``flushAllBlocking(timeout:)`` で）。
    ///
    /// Creates a registry separate from `shared`, for host tests that shouldn't put reporters in the process-wide
    /// one (pass it as `registry:` when creating a reporter). At quit, apps normally flush only `shared`, with
    /// ``flushAllBlocking(timeout:)``.
    public init() {}

    func register(_ reporter: StackNestProgressReporter) {
        entries.removeAll { $0.reporter == nil }
        entries.append(Entry(reporter: reporter))
    }

    /// 送っていない位置か送信中のものがある役が 1 つでもあるか。 / Whether any reporter has unsent work.
    public var hasUnsentWork: Bool { entries.contains { $0.reporter?.hasUnsentWork == true } }

    /// 送っていない役をすべて今すぐ送り（閉じるときと同じ扱い）、送り切るか `timeout` が来たら `completion` を
    /// 1 度だけ（メインキューの次の周で）呼ぶ。上限はメインキューのタイマーで数える（協調スレッドが混んでいても戻る）。
    /// 送り切りの途中なら何もせず false。
    ///
    /// **終了時には使わず、``flushAllBlocking(timeout:)`` を使う。**送り終えたかの確かめも、`completion` も、
    /// `timeout` の上限も、メインキューが回らないと進まない。`applicationShouldTerminate` で `.terminateLater` を返し、
    /// `completion` から `reply(toApplicationShouldTerminate:)` を呼ぶ形は、終了がメインキューの仕事の中から
    /// 求められたとき（`DispatchQueue.main.async` や `Task { @MainActor in }` の中の `NSApp.terminate(nil)`）に
    /// 止まったままになる。AppKit はその仕事の中で応答を待つ入れ子の run loop を回すが、メインキューは入れ子では
    /// 回らないので、`completion` も上限のタイマーも呼ばれない。
    ///
    /// Flushes every reporter (as on close) and calls `completion` once — after all sends finish or `timeout`
    /// passes, whichever comes first. The limit runs on a main-queue timer. Returns false, doing nothing, while a
    /// flush is already in progress.
    ///
    /// **Don't use it at quit; use ``flushAllBlocking(timeout:)``.** Noticing that the sends finished, `completion`
    /// and the `timeout` limit all need the main queue to run. Returning `.terminateLater` from
    /// `applicationShouldTerminate` and calling `reply(toApplicationShouldTerminate:)` from `completion` hangs when
    /// termination is requested from inside a main-queue job (`NSApp.terminate(nil)` inside `DispatchQueue.main.async`
    /// or `Task { @MainActor in }`): AppKit waits for the reply in a nested run loop inside that job, the main queue is
    /// not drained re-entrantly, and neither `completion` nor the limit's timer ever runs.
    @discardableResult
    public func flushAll(timeout: Duration = .seconds(2), completion: @escaping @MainActor () -> Void) -> Bool {
        guard !isFlushing else { return false }
        isFlushing = true
        let active = entries.compactMap(\.reporter).filter(\.hasUnsentWork)
        let once = OnceFlag()
        let finish: @MainActor () -> Void = { [weak self] in
            guard once.claim() else { return }
            self?.isFlushing = false
            completion()
        }
        guard !active.isEmpty else {
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
            return true
        }
        for reporter in active { reporter.close() }
        Task { @MainActor in
            for reporter in active { await reporter.waitUntilIdle() }
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout.timeInterval) { MainActor.assumeIsolated { finish() } }
        return true
    }

    /// 役が載っているか（試験が見る）。
    func containsForTesting(_ reporter: StackNestProgressReporter) -> Bool {
        entries.contains { $0.reporter === reporter }
    }

    /// 送っていない役をすべて、メインスレッドを使わずに今すぐ送り、送り切るか `timeout` が来るまで呼んだスレッドを
    /// ブロックして待つ。返すのは、送るか待つかした役の数（無ければ 0 で、すぐ戻る）。終了時に
    /// `applicationShouldTerminate` から呼び、`.terminateNow` を返す。メインキューの仕事の中から終了が求められても
    /// 止まらない（送信はメインスレッドの外で走り、呼んだスレッドは `DispatchGroup` で待つ）。
    ///
    /// - 送るのは、各役の止まっているページ（まとめ待ちのものを含む）。StackNest が知っているページ（開いたページ・
    ///   送れたページ）は送らない。
    /// - 送信が飛んでいる役は、それを送り直さずに終わりを待ち、止まっているページをその後に送る（古い位置が新しい
    ///   位置の後に届かない）。飛んでいるのと同じページは送り直さない（その送信が失敗しても、`close()` と同じく）。
    ///   飛んでいた送信が恒久的な失敗なら、後のページも送らない。
    /// - 役は閉じた扱いになり（`note(page:)` は無視される）、以後は送らない。`hasUnsentWork` は false になる。
    ///   送り切れずに `timeout` が来ても同じ（送信はそのまま続き、終了しなければ後で届くことがある）。
    ///   送るものが実は無かった役（止まっているのが StackNest の知っているページだけの役など）も、`hasUnsentWork` が
    ///   真なら閉じる。その役は返す数には入らない。
    /// - この送り切りが送るページの失敗は `onFailure` へ知らせない。呼ぶ前から飛んでいた送信の失敗は、メインアクターが
    ///   回れば（終了せずに続けたとき）これまでどおり知らせる。
    /// - 送り先を差し替えた役（`init(startPage:timing:send:onFailure:)`）では、その送り先がメインアクターを要るなら、
    ///   待ちの間は進まず `timeout` で戻る。
    ///
    /// Sends every reporter's unsent position now, without using the main thread, and blocks the calling thread until
    /// the sends finish or `timeout` passes. Returns how many reporters it sent or waited for (0, at once, when there is
    /// nothing to send). Call it from `applicationShouldTerminate` at quit and return `.terminateNow`. It works even
    /// when termination is requested from inside a main-queue job: the sends run off the main thread and the calling
    /// thread waits on a `DispatchGroup`.
    ///
    /// - It sends each reporter's waiting page (including one in the batching wait), unless StackNest already has it
    ///   (the start page or a page already sent).
    /// - A send already in flight is not repeated; the waiting page goes after it finishes, so an older position never
    ///   lands after a newer one. The in-flight page itself is not sent again, even if that send fails (as with
    ///   `close()`), and after a permanent failure of that send nothing more is sent.
    /// - The reporters count as closed (`note(page:)` is ignored) and send nothing more; `hasUnsentWork` becomes false.
    ///   This holds even when `timeout` passes first (the sends carry on and may still arrive if the app keeps running).
    ///   A reporter whose `hasUnsentWork` was true is closed even if it turns out to have nothing to send (say, only a
    ///   page StackNest already has is waiting); such a reporter is not counted in the result.
    /// - Failures of the pages this flush sends are not reported to `onFailure`. A send that was already in flight
    ///   before the call still reports its failure as before, once the main actor runs (if the app keeps running).
    /// - With a custom sender (`init(startPage:timing:send:onFailure:)`) that needs the main actor, the send cannot
    ///   progress during the wait, and the call returns at `timeout`.
    @discardableResult
    public func flushAllBlocking(timeout: Duration = .seconds(2)) -> Int {
        let jobs = entries.compactMap { $0.reporter?.takeWorkForBlockingFlush() }
        guard !jobs.isEmpty else { return 0 }
        // 送信はメインアクターの外（切り離したタスク）で走らせ、メインスレッドはグループで待つ。メインキューにも
        // メインアクターにも何も積まないので、メインキューの仕事の中から呼ばれても進む。
        let group = DispatchGroup()
        for job in jobs {
            group.enter()
            Task.detached(priority: .userInitiated) {
                await job.run()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout.timeInterval)
        return jobs.count
    }

    /// 1 度だけ真を返す印（送り切りとタイマーのどちらが先でも、completion を 1 度だけ呼ぶ）。
    @MainActor private final class OnceFlag {
        private var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
