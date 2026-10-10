import Foundation

/// 同期の読み出し API を持つビューアのための橋渡し。**ホストが用意した「ブロックしてよいスレッド」からだけ呼ぶ**
/// （協調スレッド・メインスレッドからは呼ばない）。この道は `Task` を作らず、actor へ入らず、`await` しないので、
/// 協調スレッドが全部ふさがっていても進む（協調スレッドの上でブロックして待つと、普通の `Task` が長く動かなくなる。
/// qooViewer の `FileIO` の実測に倣う）。
///
/// A bridge for viewers whose reading API is synchronous. **Call it only from a thread the host lets block**
/// (never from the main thread or the cooperative pool). It never creates a `Task`, enters an actor or awaits,
/// so it makes progress even when the cooperative pool is saturated.
public struct StackNestBlockingReader: Sendable {
    /// 読んでいるセッション。 / The session being read.
    public let session: StackNestBookSession
    private let isCancelled: @Sendable () -> Bool
    private let onMisuse: @Sendable (String) -> Void

    /// `isCancelled` はホストの取り消しの旗（借りたスレッドでは `Task.isCancelled` が常に false のため）。
    ///
    /// `isCancelled` is the host's cancellation flag (`Task.isCancelled` is always false on a borrowed thread).
    public init(session: StackNestBookSession, isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.init(session: session, isCancelled: isCancelled, onMisuse: { assertionFailure($0) })
    }

    /// 呼び出し方の誤りの知らせを差し替える形（試験用。既定は Debug で止める `assertionFailure`）。
    init(session: StackNestBookSession, isCancelled: @escaping @Sendable () -> Bool,
         onMisuse: @escaping @Sendable (String) -> Void)
    {
        self.session = session
        self.isCancelled = isCancelled
        self.onMisuse = onMisuse
    }

    /// manifest（同期）。閉じた後は、覚えた manifest があっても、要求なしで `CancellationError`。
    ///
    /// The manifest, synchronously. After `close()` it throws `CancellationError` without a request,
    /// even if a manifest was already read.
    public func manifest(refresh: Bool = false) throws -> StackNestBookManifest {
        checkCallingThread()
        if !refresh, let cached = session.cachedManifest { return cached }
        return try session.recordManifest(
            try session.fetchBlocking(.manifest, priority: .display, isCancelled: isCancelled))
    }

    /// ページ（同期。`index` は StackNest のページ番号）。範囲外は要求なしで `.pageOutOfRange`（ホストは自分の
    /// 「エントリが無い」に読み替える）。
    ///
    /// A page, synchronously. Out-of-range numbers fail with `.pageOutOfRange` without a request.
    ///
    /// 1 回の呼び出しで最大 3 件の要求（範囲の確かめ直し・ページ・404 の後の読み直し）を出すことがあり、`waitLimit` は
    /// 要求ごとに数えるので、最悪の場合は `waitLimit` の最大 3 倍まで待つ。閉じた後は（番号に関わらず）
    /// `CancellationError`。
    ///
    /// One call can make up to three requests (the range re-check, the page, and the re-read after a 404), and
    /// `waitLimit` is counted per request, so in the worst case it can take up to three times `waitLimit`.
    /// After `close()` it throws `CancellationError` whatever the index.
    public func page(_ index: Int, maxWidth: Int? = nil,
                     priority: StackNestRequestPriority = .display) throws -> StackNestPage
    {
        checkCallingThread()
        if session.isClosedForBlocking { throw CancellationError() }
        try session.ensureInRangeBlocking(index, isCancelled: isCancelled)
        do {
            let response = try session.fetchBlocking(
                .page(index: index, maxWidth: StackNestBookSession.normalizedWidth(maxWidth)), priority: priority,
                isCancelled: isCancelled)
            return StackNestPage(data: response.data, contentType: response.contentType)
        } catch is PageNotFound {
            let manifest: Result<StackNestBookManifest, any Error> = Result {
                try session.recordManifest(
                    try session.fetchBlocking(.manifest, priority: .display, isCancelled: isCancelled))
            }
            throw StackNestBookSession.missingPageError(index: index, manifest: manifest)
        }
    }

    /// いちばん起きやすい誤り（メインスレッド・`Task` の中から呼ぶ）を知らせる。完全な検出ではない。
    private func checkCallingThread() {
        if Thread.isMainThread {
            onMisuse("StackNestBlockingReader was called on the main thread; call it on a thread that may block.")
        } else if withUnsafeCurrentTask(body: { $0 != nil }) {
            onMisuse("StackNestBlockingReader was called inside a Task; call it on a thread that may block.")
        }
    }
}

/// 同期の顔（エンジンの側）。`Task` を作らず、`await` しない。
extension StackNestBookSession {
    /// 同期の待つ人として加わる（`Task` を作らず、`await` しない）。要求を出す前に取り消しを見る。
    /// `cancellationPollInterval`（0.1 秒）ごとに取り消しを見て、`waitLimit` を超えたら `.cannotConnect`。抜けられ
    /// なかった（相手が再開の権利を取った）ときは、すぐ届く結果を受け取る。その待ちにも上限を置く（再開の権利の
    /// 決まりが将来の直しで崩れても、決して永遠に返らない、にならないように）。
    func fetchBlocking(_ key: RequestKey, priority: StackNestRequestPriority,
                       isCancelled: () -> Bool) throws -> FetchedResponse
    {
        if isCancelled() { throw CancellationError() }
        let slot = BlockingSlot()
        let ticket = lock.withLock { allocateTicketLocked() }
        perform(key, priority: priority, ticket: ticket, waiter: .blocking(slot))
        let deadline = DispatchTime.now() + configuration.waitLimit.timeInterval
        let poll = Self.cancellationPollInterval.timeInterval
        while true {
            if let result = slot.waitForResult(until: .now() + poll) { return try result.get() }
            let cancelled = isCancelled()
            guard cancelled || DispatchTime.now() >= deadline else { continue }
            if withdraw(ticket) != nil {
                if cancelled { throw CancellationError() }
                throw StackNestViewerError(.cannotConnect)
            }
            // 完了の側が先に権利を取った: 結果はすぐ届く。
            let grace = DispatchTime.now() + Self.resourceTimeoutMargin.timeInterval
            if let result = slot.waitForResult(until: grace) { return try result.get() }
            throw StackNestViewerError(.cannotConnect)
        }
    }

    /// 閉じているか（同期の顔が、範囲の確認より先に見る）。
    var isClosedForBlocking: Bool { lock.withLock { state.isClosed } }

    /// 範囲の確認（同期）。
    func ensureInRangeBlocking(_ index: Int, isCancelled: () -> Bool) throws {
        let (known, confirmed) = lock.withLock { (state.knownPageCount, state.hasConfirmedPageCount) }
        guard index >= 0 else { throw StackNestViewerError(.pageOutOfRange, pageCount: known) }
        if index < known { return }
        if !confirmed {
            _ = try recordManifest(try fetchBlocking(.manifest, priority: .display, isCancelled: isCancelled))
        }
        let current = lock.withLock { state.knownPageCount }
        guard index < current else { throw StackNestViewerError(.pageOutOfRange, pageCount: current) }
    }

}
