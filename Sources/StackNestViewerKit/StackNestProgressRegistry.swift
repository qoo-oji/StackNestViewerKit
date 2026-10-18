import Foundation

/// 開いている書き戻しの役を覚えておき、アプリの終了時にまとめて送り切る（⌘Q は「閉じた」を通らないため）。
/// 持つのは弱い参照だけ。AppKit への差し込み（`applicationShouldTerminate`）はホストに残す:
///
///     func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
///         let registry = StackNestProgressRegistry.shared
///         if registry.isFlushing { return .terminateLater }
///         guard registry.hasUnsentWork else { return .terminateNow }
///         registry.flushAll(timeout: .seconds(2)) { sender.reply(toApplicationShouldTerminate: true) }
///         return .terminateLater
///     }
///
/// Remembers open reporters (weakly) and flushes them all when the app quits.
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
    /// （役を作るときに `registry:` で渡す）。アプリの終了時に送り切るのは、ふつうは `shared` だけ。
    ///
    /// Creates a registry separate from `shared`, for host tests that shouldn't put reporters in the process-wide
    /// one (pass it as `registry:` when creating a reporter). At quit, apps normally flush only `shared`.
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
    /// Flushes every reporter (as on close) and calls `completion` once — after all sends finish or `timeout`
    /// passes, whichever comes first. The limit runs on a main-queue timer. Returns false, doing nothing, while a
    /// flush is already in progress.
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
