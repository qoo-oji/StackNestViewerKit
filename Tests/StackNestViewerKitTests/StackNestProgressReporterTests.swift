import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// 送るたびの結果を順に決める送り先（nil = 成功。使い切った後は成功）。`slowPage` のページは送信を遅らせ、
/// `hangs` なら 5 秒止まる。同時に飛んだ送信の最大数も数える。
final class ScriptedSend: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [StackNestViewerError?]
    private var delivered: [Int] = []
    private var attempts = 0
    private var inFlight = 0
    private var peak = 0
    private let slowPage: Int?
    private let hangs: Bool

    init(_ outcomes: [StackNestViewerError?] = [], slowPage: Int? = nil, hangs: Bool = false) {
        self.outcomes = outcomes
        self.slowPage = slowPage
        self.hangs = hangs
    }

    func send(_ page: Int) async throws {
        let outcome = lock.withLock { () -> StackNestViewerError? in
            attempts += 1
            inFlight += 1
            peak = max(peak, inFlight)
            return outcomes.isEmpty ? nil : outcomes.removeFirst()
        }
        defer { lock.withLock { inFlight -= 1 } }
        if hangs { try? await Task.sleep(for: .seconds(5)) }
        if page == slowPage { try? await Task.sleep(for: .milliseconds(50)) }
        if let outcome { throw outcome }
        lock.withLock { delivered.append(page) }
    }

    var pages: [Int] { lock.withLock { delivered } }
    var attemptCount: Int { lock.withLock { attempts } }
    var maxConcurrentSends: Int { lock.withLock { peak } }
}

@MainActor
final class FailureLog {
    var failures: [StackNestViewerError] = []
}

/// 書き戻しの役: まとめ・最長の待ち・1 件ずつと置き換え・すぐには送り直さない・恒久的な失敗で止まる・
/// 知らせを重ねない・開いたページを送らない・閉じるときの送り切りと 1 度だけの再試行。
@MainActor
@Suite("書き戻しの役")
struct StackNestProgressReporterTests {
    private func reporter(_ sent: ScriptedSend, startPage: Int? = 0, debounce: Duration = .seconds(60),
                          maxWait: Duration = .seconds(60), log: FailureLog? = nil,
                          registry: StackNestProgressRegistry = StackNestProgressRegistry()) -> StackNestProgressReporter
    {
        var timing = StackNestProgressReporter.Timing()
        timing.debounce = debounce
        timing.maxWait = maxWait
        return StackNestProgressReporter(startPage: startPage, timing: timing, registry: registry,
                                         send: { try await sent.send($0) }, onFailure: { log?.failures.append($0) })
    }

    @Test("既定のまとめは 3 秒・最長 10 秒")
    func defaultTiming() {
        let timing = StackNestProgressReporter.Timing()
        #expect(timing.debounce == .seconds(3))
        #expect(timing.maxWait == .seconds(10))
    }

    @Test("続けてページを送っても、まとめ待ちの後に最後のページを 1 回だけ送る")
    func debounceSendsTheLastPageOnce() async {
        let sent = ScriptedSend()
        let progress = reporter(sent, debounce: .milliseconds(20))
        progress.note(page: 3)
        progress.note(page: 5)
        #expect(sent.pages.isEmpty)
        await progress.waitUntilIdle()
        #expect(sent.pages == [5])
    }

    @Test("flush は待たずに送る")
    func flushSendsImmediately() async {
        let sent = ScriptedSend()
        let progress = reporter(sent)
        progress.note(page: 7)
        progress.flush()
        await progress.waitUntilIdle()
        #expect(sent.pages == [7])
    }

    @Test("開いたページと、送ったばかりのページは送らない。負の値は無視する")
    func skipsPagesStackNestAlreadyKnows() async {
        let sent = ScriptedSend()
        let progress = reporter(sent, startPage: 4)
        progress.note(page: 4)
        progress.flush()
        progress.note(page: -1)
        progress.flush()
        progress.note(page: 6)
        progress.flush()
        progress.note(page: 6)
        progress.flush()
        await progress.waitUntilIdle()
        #expect(sent.pages == [6])
        #expect(sent.attemptCount == 1)
    }

    @Test("送信中に止まったページは最新の 1 件だけを残し、送信が終わってから続けて送る（飛ぶのは常に 1 件）")
    func collapsesPagesNotedWhileSending() async {
        let sent = ScriptedSend(slowPage: 1)
        let progress = reporter(sent)
        progress.note(page: 1)
        progress.flush()
        progress.note(page: 2)
        progress.flush()
        progress.note(page: 3)
        progress.flush()
        await progress.waitUntilIdle()
        #expect(sent.pages == [1, 3])
        #expect(sent.maxConcurrentSends == 1)
    }

    @Test("送信が失敗したら、その間に止まったページがあってもすぐには送らない（次の note・flush を待つ）")
    func failureDoesNotResendImmediately() async {
        let sent = ScriptedSend([StackNestViewerError(.cannotConnect)], slowPage: 1)
        let log = FailureLog()
        let progress = reporter(sent, log: log)
        progress.note(page: 1)
        progress.flush()
        progress.note(page: 2)
        // 2 番のまとめ待ち（60 秒）は残したまま、1 番の送信の失敗だけを待つ。
        while log.failures.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.attemptCount == 1)
        #expect(log.failures == [StackNestViewerError(.cannotConnect)])
        progress.flush()
        await progress.waitUntilIdle()
        #expect(sent.pages == [2])
    }

    @Test("続けてページを送り続けても、まとめ待ちの最長で送る")
    func maxWaitSendsWhileKeepingTurningPages() async {
        let sent = ScriptedSend()
        let progress = reporter(sent, debounce: .milliseconds(100), maxWait: .milliseconds(150))
        for page in 1...20 {
            progress.note(page: page)
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(sent.pages.count >= 1)
        await progress.waitUntilIdle()
        #expect(sent.pages.last == 20)
    }

    @Test("閉じるときに飛んでいた送信が失敗しても、止まっていた新しいページを 1 度だけ試す")
    func failedInFlightSendAtCloseTriesTheNewerPageOnce() async {
        let failure = StackNestViewerError(.cannotConnect)
        let sent = ScriptedSend([failure, failure, nil], slowPage: 1)
        let progress = reporter(sent)
        progress.note(page: 1)
        progress.flush()
        progress.note(page: 2)
        progress.close()
        await progress.waitUntilIdle()
        #expect(sent.attemptCount == 2)
        #expect(sent.pages.isEmpty)
    }

    @Test("flush（閉じない）では、飛んでいた送信が失敗しても送り直さない")
    func flushWithoutCloseDoesNotRetry() async {
        let sent = ScriptedSend([StackNestViewerError(.cannotConnect)], slowPage: 1)
        let progress = reporter(sent)
        progress.note(page: 1)
        progress.flush()
        progress.note(page: 2)
        progress.flush()
        while sent.attemptCount < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sent.attemptCount == 1)
    }

    @Test("恒久的な失敗（期限切れ・認証失敗・本が無い・ライブラリのロック・つないでよくないホスト）の後は送らない")
    func permanentFailureStopsSending() async {
        for code in [StackNestViewerError.Code.unauthorized, .expired, .bookNotFound, .libraryLocked, .hostNotAllowed] {
            let sent = ScriptedSend([StackNestViewerError(code)])
            let log = FailureLog()
            let progress = reporter(sent, log: log)
            progress.note(page: 1)
            progress.flush()
            await progress.waitUntilIdle()
            progress.note(page: 2)
            progress.flush()
            await progress.waitUntilIdle()
            #expect(sent.attemptCount == 1, "\(code.rawValue)")
            #expect(log.failures == [StackNestViewerError(code)])
            #expect(progress.isStopped)
            #expect(!progress.hasUnsentWork)
        }
    }

    @Test("一時的な失敗では止まらない")
    func transientFailureDoesNotStopSending() async {
        let sent = ScriptedSend([StackNestViewerError(.cannotConnect), StackNestViewerError(.remoteUnavailable)])
        let progress = reporter(sent)
        for page in 1...3 {
            progress.note(page: page)
            progress.flush()
            await progress.waitUntilIdle()
        }
        #expect(sent.attemptCount == 3)
        #expect(sent.pages == [3])
        #expect(!progress.isStopped)
    }

    @Test("知らせは種類ごとに 1 度。httpStatus は状態コードごと。成功したら出し直せる")
    func noticesAreNotRepeated() async {
        let sent = ScriptedSend([
            StackNestViewerError(.httpStatus, statusCode: 500), StackNestViewerError(.httpStatus, statusCode: 500),
            StackNestViewerError(.httpStatus, statusCode: 503), nil, StackNestViewerError(.httpStatus, statusCode: 503),
        ])
        let log = FailureLog()
        let progress = reporter(sent, log: log)
        for page in 1...5 {
            progress.note(page: page)
            progress.flush()
            await progress.waitUntilIdle()
        }
        #expect(log.failures.map(\.statusCode) == [500, 503, 503])
    }

    @Test("Registry: 作ると登録簿に載り、手放すと数えない")
    func registersAndForgets() async {
        let registry = StackNestProgressRegistry()
        let sent = ScriptedSend()
        var progress: StackNestProgressReporter? = reporter(sent, registry: registry)
        progress?.note(page: 2)
        #expect(registry.hasUnsentWork)
        progress = nil
        #expect(!registry.hasUnsentWork)
    }

    @Test("セッションへ書き戻す（鍵と名乗り付きの POST）。閉じたセッションでも送り、送り切ったら解放される")
    func sessionIsReleasedAfterCloseAndReporterIdle() async throws {
        let stub = StackNestStubServer()
        let sessionRef: WeakBox
        do {
            let session = try makeSession(stub)
            // 共有の登録簿（公開 API の試験が送り切りを試す）を触らないよう、別の登録簿に載せる。
            let progress = StackNestProgressReporter(
                startPage: 0, timing: .init(), registry: StackNestProgressRegistry(),
                send: { [session] page in try await session.postProgress(page: page) }, onFailure: { _ in })
            sessionRef = WeakBox(session)
            progress.note(page: 2)
            session.close()
            progress.close()
            await progress.waitUntilIdle()
        }
        #expect(stub.requests.map(\.progressPage) == [2])
        #expect(stub.requests.allSatisfy { $0.carriesExpectedToken })
        #expect(await waitUntil { sessionRef.isReleased })
    }
}

/// 終了時の送り切り。
@MainActor
@Suite("書き戻しの登録簿")
struct StackNestProgressRegistryTests {
    private func reporter(_ sent: ScriptedSend, _ registry: StackNestProgressRegistry) -> StackNestProgressReporter {
        StackNestProgressReporter(startPage: 0, timing: .init(), registry: registry,
                                  send: { try await sent.send($0) }, onFailure: { _ in })
    }

    /// `flushAll` の completion が呼ばれるまで待つ（呼ばれた回数を数える）。
    private final class Completions {
        var count = 0
    }

    @Test("送るものが無ければ、すぐ（次の周で）completion を呼ぶ")
    func completesAtOnceWithNothingToSend() async {
        let registry = StackNestProgressRegistry()
        let sent = ScriptedSend()
        let progress = reporter(sent, registry)
        _ = progress
        let done = Completions()
        #expect(registry.flushAll(timeout: .seconds(30)) { done.count += 1 })
        #expect(done.count == 0, "その場では呼ばない（terminateLater を返した後に応答するため）")
        while done.count == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(sent.attemptCount == 0)
        #expect(!registry.isFlushing)
    }

    @Test("まとめ待ちの位置をすべて今すぐ送り、送り終えたら completion を 1 度だけ呼ぶ")
    func flushesEveryReporter() async {
        let registry = StackNestProgressRegistry()
        let first = ScriptedSend()
        let second = ScriptedSend()
        let a = reporter(first, registry)
        let b = reporter(second, registry)
        a.note(page: 4)
        b.note(page: 9)
        #expect(registry.hasUnsentWork)
        let done = Completions()
        registry.flushAll(timeout: .seconds(30)) { done.count += 1 }
        while done.count == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(first.pages == [4])
        #expect(second.pages == [9])
        #expect(!registry.hasUnsentWork)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.count == 1)
    }

    @Test("StackNest が答えなくても、timeout で必ず戻る。待ちの途中の 2 度目は始めない")
    func returnsAtTheCapAndRefusesReentry() async {
        let registry = StackNestProgressRegistry()
        let sent = ScriptedSend(hangs: true)
        let progress = reporter(sent, registry)
        progress.note(page: 4)
        let done = Completions()
        let start = ContinuousClock.now
        #expect(registry.flushAll(timeout: .milliseconds(150)) { done.count += 1 })
        #expect(registry.isFlushing)
        #expect(!registry.flushAll(timeout: .milliseconds(150)) { done.count += 100 })
        while done.count == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(done.count == 1)
        #expect(!registry.isFlushing)
        #expect(sent.attemptCount == 1)
    }
}
