import Foundation

/// 読み進めたページを StackNest へ書き戻す役（1 冊に 1 つ）。ページの合図は UI から来るので MainActor に置く
/// （呼び出しの順がそのまま送る順になる）。
///
/// - まとめる: `note(page:)` のたびに 3 秒の待ちをやり直す。ただし最初に止まってから 10 秒を超えては待たない。
/// - 飛ぶのは 1 件、待つのは最新の 1 件: 送信中に止まったページは「次に送るページ」を置き換えるだけで、送信が
///   成功したら続けて送る（古い位置が新しい位置の後に届いて巻き戻すことが無い）。
/// - すぐには送り直さない: 失敗したページは次の `note`・`flush`・`close` まで送らない。
/// - 恒久的な失敗（`isPermanent`）の後は、その本については送らない。
/// - 知らせは種類（`noticeKind`）ごとに 1 度。送れたら記憶を消す。
/// - 開いたページ（`startPage`）と、送った（送っている）ページは送らない。
/// - 書き戻すのは StackNest のページ番号で、ビューアー自身の一覧の位置ではない。
/// - `close()` の後の `note(page:)` は無視する。
///
/// Writes the reading position back to StackNest (one per open book). Main-actor isolated, so the order of
/// calls is the order of sends. Batches for 3 seconds (at most 10), keeps one send in flight and only the
/// newest waiting page, doesn't retry on its own, stops after a permanent failure and reports each kind of
/// failure once. **Pages are StackNest page numbers, not positions in the viewer's own list.**
@MainActor
public final class StackNestProgressReporter {
    /// まとめの時間。 / Batching times.
    public struct Timing: Sendable {
        /// 止まってから送るまで。 / Delay after the last page change.
        public var debounce: Duration = .seconds(3)
        /// 最初に止まってから、これを超えては待たない。 / The longest wait from the first pending change.
        public var maxWait: Duration = .seconds(10)
        /// 既定のまとめ（3 秒・最長 10 秒）。 / The defaults (3 seconds, at most 10).
        public init() {}
    }

    /// 1 ページ分の送り先（StackNest のページ番号を受け取る）。 / The sender for one page (takes a StackNest page number).
    public typealias Send = @Sendable (Int) async throws -> Void

    private let timing: Timing
    private let send: Send
    private let onFailure: @MainActor (StackNestViewerError) -> Void
    private var pendingPage: Int?
    private var lastSentPage: Int?
    private var debounceTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var lastNotice: StackNestViewerError.NoticeKind?
    private var firstPendingAt: ContinuousClock.Instant?
    private var closeDeferred = false
    private var retriedAfterClose = false
    private var isClosed = false
    /// 恒久的な失敗の後（送らない）。 / True after a permanent failure (nothing more is sent).
    public private(set) var isStopped = false

    /// セッションへ書き戻す役を作り、`StackNestProgressRegistry.shared` に弱い参照で載せる（終了時の送り切りのため）。
    /// 役は（閉じた後も）手放されるまでセッションを強く持つ。
    ///
    /// Creates a reporter that posts to `session` and registers it (weakly) with
    /// `StackNestProgressRegistry.shared` for the quit-time flush. It keeps the session alive for as long as the reporter itself
    /// is alive, even after `close()`; release the reporter when the book closes.
    public convenience init(session: StackNestBookSession, startPage: Int?, timing: Timing = .init(),
                            onFailure: @escaping @MainActor (StackNestViewerError) -> Void)
    {
        self.init(startPage: startPage, timing: timing, send: { page in try await session.postProgress(page: page) },
                  onFailure: onFailure)
    }

    /// 送り先を差し替える形（試験・独自の通信を持つホスト）。これも `StackNestProgressRegistry.shared` に載る。
    ///
    /// Takes a custom sender (tests, or hosts with their own transport). Also registers with the shared registry.
    public convenience init(startPage: Int?, timing: Timing = .init(), send: @escaping Send,
                            onFailure: @escaping @MainActor (StackNestViewerError) -> Void)
    {
        self.init(startPage: startPage, timing: timing, registry: .shared, send: send, onFailure: onFailure)
    }

    /// 登録簿を選べる形（試験が共有の登録簿を汚さないため）。
    init(startPage: Int?, timing: Timing, registry: StackNestProgressRegistry, send: @escaping Send,
         onFailure: @escaping @MainActor (StackNestViewerError) -> Void)
    {
        lastSentPage = startPage
        self.timing = timing
        self.send = send
        self.onFailure = onFailure
        registry.register(self)
    }

    /// 今いるページ（StackNest のページ番号）。まとめ待ちをやり直す。負の値は無視する。
    /// `close()` の後は無視する（閉じる間に先頭へ戻るビューアーが、保存した位置を上書きしないため）。
    ///
    /// The current page (a StackNest page number). Restarts the batching wait. Negative values are ignored.
    /// Ignored after `close()` (so a viewer resetting to page 0 while closing cannot overwrite the saved position).
    public func note(page: Int) {
        guard !isStopped, !isClosed, page >= 0 else { return }
        if page == lastSentPage, pendingPage == nil { return }
        pendingPage = page
        let now = ContinuousClock.now
        let start = firstPendingAt ?? now
        firstPendingAt = start
        let delay = min(timing.debounce, max(timing.maxWait - (now - start), .zero))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sendPending()
        }
    }

    /// まとめ待ちをやめて今すぐ送る（送信中なら、それが成功した後に送る）。
    ///
    /// Sends now instead of waiting (after the in-flight send succeeds, if there is one).
    public func flush() {
        guard !isStopped else { return }
        debounceTask?.cancel()
        debounceTask = nil
        sendPending()
    }

    /// 閉じるとき: 今すぐ送る。飛んでいる送信があれば、それが終わってから止まっていたページを送り、閉じる前から
    /// 飛んでいた送信が失敗したら、止まっていた新しいページを 1 度だけ試す（閉じた後は次の合図が来ないため）。
    /// 役は送り切るまで自分を保つ。閉じた後の `note(page:)` は無視する。
    ///
    /// On close: sends now. If a send was in flight, the waiting page goes after it; if that earlier send fails,
    /// the newer page is tried once. The reporter keeps itself alive until done. `note(page:)` is ignored afterwards.
    public func close() {
        guard !isStopped else { return }
        isClosed = true
        if inFlight != nil, pendingPage != nil { closeDeferred = true }
        flush()
    }

    /// 送っていない・送っている最中の位置があるか。 / Whether a position is waiting or being sent.
    public var hasUnsentWork: Bool { !isStopped && (pendingPage != nil || debounceTask != nil || inFlight != nil) }

    /// まとめ待ちと送信（続けて送る分も）が終わるまで待つ（試験・終了時）。
    ///
    /// Waits until the batching wait and all sends finish (for tests and quitting).
    public func waitUntilIdle() async {
        while true {
            if let debounceTask {
                await debounceTask.value
                if self.debounceTask == debounceTask { self.debounceTask = nil }
                continue
            }
            if let inFlight {
                await inFlight.value
                continue
            }
            return
        }
    }

    private func sendPending() {
        // まとめ待ちを残さない（取り消さずに外すと、手の届かないタスクが後で早く発火して、失敗で戻したページを送り直す）。
        debounceTask?.cancel()
        debounceTask = nil
        guard !isStopped, inFlight == nil, let page = pendingPage else { return }
        pendingPage = nil
        firstPendingAt = nil
        guard page != lastSentPage else { return }
        lastSentPage = page
        let send = send
        // self を強く持つ: 閉じた後（ホストが手放した後）も、飛んでいる送信と続けて送るページを送り切る。
        inFlight = Task { [self] in
            var succeeded = false
            do {
                try await send(page)
                succeeded = true
                lastNotice = nil
            } catch {
                handle(error, page: page)
            }
            inFlight = nil
            if succeeded {
                sendPending()
            } else if closeDeferred, !retriedAfterClose, let newer = pendingPage, newer != page {
                retriedAfterClose = true
                sendPending()
            }
        }
    }

    private func handle(_ error: any Error, page: Int) {
        // 送れなかったページは次の機会に送る。その後で別のページが止まっていれば、そちらが新しいので戻さない。
        if lastSentPage == page {
            lastSentPage = nil
            if pendingPage == nil { pendingPage = page }
        }
        guard let failure = error as? StackNestViewerError else { return }
        if failure.isPermanent { isStopped = true }
        guard failure.noticeKind != lastNotice else { return }
        lastNotice = failure.noticeKind
        onFailure(failure)
    }
}
