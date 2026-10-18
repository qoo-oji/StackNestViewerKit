import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// 同時の数: 出す要求は `maxConcurrentRequests` まで。残りはセッションの列で待ち、書き戻し → 表示 → 先読みの順に
/// 出る（`URLSession` の中の列では、優先度は目安にしかならない）。
@Suite("セッション: 同時の数")
struct StackNestConcurrencyTests {
    private func pageKey(_ index: Int) -> RequestKey { .page(index: index, maxWidth: nil) }

    @Test("同時に出す要求は既定で 6 件まで。残りは列で待ち、枠が空いたら出す", .timeLimit(.minutes(1)))
    func requestsAreBoundedByDefault() async throws {
        let stub = StackNestStubServer(pageCount: 10)
        let gates = (0..<10).map { stub.gate(.page($0)) }
        defer { gates.forEach { $0.open() } }
        let session = try makeSession(stub)
        #expect(StackNestBookSession.Configuration().maxConcurrentRequests == 6)
        let readers = (0..<10).map { index in Task { try await session.page(index) } }
        #expect(await waitUntil { stub.requests.count == 6 && session.queuedKeysForTesting.count == 4 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.count == 6, "7 件目は StackNest へ届かない")
        let first = try #require(stub.requests.first?.route)
        if case .page(let index) = first { gates[index].open() }
        #expect(await waitUntil { stub.requests.count == 7 }, "1 件終われば次の 1 件が出る")
        gates.forEach { $0.open() }
        for (index, reader) in readers.enumerated() {
            #expect(StackNestFixtures.marker(of: try await reader.value.data) == index)
        }
        #expect(stub.requests.count == 10)
        #expect(await waitUntil { session.runningCountForTesting == 0 }, "枠はすべて返る")
    }

    @Test("枠が空いたら、表示の要求の件を先読みだけの件より先に出す", .timeLimit(.minutes(1)))
    func displayIsAdmittedBeforePrefetch() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 1 }
        let holder = Task { try await session.page(0) }
        #expect(await gate.arrival())
        session.prefetch([1, 2])
        let shown = Task { try await session.page(5) }
        #expect(await waitUntil { session.queuedKeysForTesting == [pageKey(1), pageKey(2), pageKey(5)] })
        gate.open()
        _ = try await holder.value
        #expect(StackNestFixtures.marker(of: try await shown.value.data) == 5)
        #expect(await waitUntil { stub.requests.count == 4 })
        #expect(stub.requests.map(\.route) == [.page(0), .page(5), .page(1), .page(2)])
    }

    @Test("列で待つ先読みの件に表示の要求が乗ったら、その場で前へ出る", .timeLimit(.minutes(1)))
    func queuedPrefetchJoinedByDisplayMovesAhead() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 1 }
        let holder = Task { try await session.page(0) }
        #expect(await gate.arrival())
        session.prefetch([1, 2])
        #expect(await waitUntil { session.queuedKeysForTesting == [pageKey(1), pageKey(2)] })
        let shown = Task { try await session.page(2) }
        #expect(await waitUntil { session.waiterCountForTesting(pageKey(2)) == 2 })
        gate.open()
        _ = try await holder.value
        #expect(StackNestFixtures.marker(of: try await shown.value.data) == 2)
        #expect(await waitUntil { stub.requests.count == 3 })
        #expect(stub.requests.map(\.route) == [.page(0), .page(2), .page(1)])
        #expect(stub.requestCount(.page(2)) == 1, "乗った件は 1 件のまま")
    }

    @Test("書き戻しは、待っているページの取得より先に出る（列の先頭）", .timeLimit(.minutes(1)))
    func progressIsAdmittedFirst() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 1 }
        let holder = Task { try await session.page(0) }
        #expect(await gate.arrival())
        let shown = Task { try await session.page(1) }
        #expect(await waitUntil { session.queuedKeysForTesting == [pageKey(1)] })
        let progress = Task { try await session.postProgress(page: 3) }
        #expect(await waitUntil { session.queuedKeysForTesting.count == 2 })
        gate.open()
        _ = try await holder.value
        _ = try await shown.value
        try await progress.value
        #expect(stub.requests.map(\.route) == [.page(0), .progress, .page(1)])
    }

    @Test("列で待つ間に待つ人が誰もいなくなった件は、要求を出さずに外す", .timeLimit(.minutes(1)))
    func withdrawnQueuedFlightIsDroppedWithoutARequest() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 1 }
        let holder = Task { try await session.page(0) }
        #expect(await gate.arrival())
        let waiting = Task { try await session.page(1) }
        #expect(await waitUntil { session.queuedKeysForTesting == [pageKey(1)] })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(session.queuedKeysForTesting.isEmpty)
        gate.open()
        _ = try await holder.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.map(\.route) == [.page(0)])
        #expect(session.ticketCountForTesting == 0)
        #expect(await waitUntil { session.runningCountForTesting == 0 })
    }

    @Test("恒久的な失敗の後は、列で待つ先読みだけの件を出さない", .timeLimit(.minutes(1)))
    func permanentFailureDropsQueuedPrefetches() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        stub.respond(.page(0), with: .status(401))
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 1 }
        let holder = Task { try await session.page(0) }
        #expect(await gate.arrival())
        session.prefetch([1, 2])
        #expect(await waitUntil { session.queuedKeysForTesting == [pageKey(1), pageKey(2)] })
        gate.open()
        await #expect(throws: StackNestViewerError(.unauthorized)) { try await holder.value }
        #expect(await waitUntil { session.queuedKeysForTesting.isEmpty })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.map(\.route) == [.page(0)])
    }

    @Test("列で待つ時間も waitLimit に数える（届かないまま .cannotConnect で戻る）", .timeLimit(.minutes(1)))
    func queueingCountsTowardWaitLimit() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) {
            $0.maxConcurrentRequests = 1
            $0.waitLimit = .milliseconds(300)
        }
        // 先読み（待つ人の時計を持たない）に枠を取らせておく。
        session.prefetch([0])
        #expect(await gate.arrival())
        let start = Date()
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await session.page(1) }
        #expect(Date().timeIntervalSince(start) < 1.5)
        #expect(session.queuedKeysForTesting.isEmpty)
        #expect(stub.requests.map(\.route) == [.page(0)])
    }

    @Test("閉じると並んでいるページの件は要求を出さずに取り消し、並んでいる書き戻しは枠が空いたら出す",
          .timeLimit(.minutes(1)))
    func closeDropsQueuedPagesButKeepsQueuedProgress() async throws {
        let stub = StackNestStubServer(pageCount: 8)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 1 }
        let holder = Task { try await session.page(0) }
        #expect(await gate.arrival())
        let waiting = Task { try await session.page(1) }
        let progress = Task { try await session.postProgress(page: 4) }
        #expect(await waitUntil { session.queuedKeysForTesting.count == 2 })
        session.close()
        await #expect(throws: CancellationError.self) { try await holder.value }
        await #expect(throws: CancellationError.self) { try await waiting.value }
        try await progress.value
        #expect(stub.requests.map(\.route) == [.page(0), .progress])
        #expect(stub.requests.last?.progressPage == 4)
    }

    @Test("URLSession の宛先ごとの接続の数を同時の数の上限に合わせる（ホストの設定の値は上書きする。1 未満は 1）")
    func connectionsPerHostFollowTheLimit() throws {
        let stub = StackNestStubServer()
        let host = URLSessionConfiguration.ephemeral
        host.httpMaximumConnectionsPerHost = 20
        let standard = try makeSession(stub) { $0.makeURLSessionConfiguration = { host } }
        #expect(standard.urlSessionConfigurationForTesting.httpMaximumConnectionsPerHost == 6)
        #expect(host.httpMaximumConnectionsPerHost == 20, "ホストの設定は書き換えない")
        let three = try makeSession(stub) { $0.maxConcurrentRequests = 3 }
        #expect(three.urlSessionConfigurationForTesting.httpMaximumConnectionsPerHost == 3)
        let zero = try makeSession(stub) { $0.maxConcurrentRequests = 0 }
        #expect(zero.urlSessionConfigurationForTesting.httpMaximumConnectionsPerHost == 1)
    }

    @Test("同期の顔も同じ列に並ぶ（同時の数を超えない）", .timeLimit(.minutes(1)))
    func blockingReadersShareTheLimit() async throws {
        let stub = StackNestStubServer(pageCount: 6)
        let gates = (0..<6).map { stub.gate(.page($0)) }
        defer { gates.forEach { $0.open() } }
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 2 }
        let reader = StackNestBlockingReader(session: session)
        let readers = (0..<6).map { index in Task { await onThread { Result { try reader.page(index) } } } }
        #expect(await waitUntil { stub.requests.count == 2 && session.queuedKeysForTesting.count == 4 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.count == 2)
        gates.forEach { $0.open() }
        for (index, reader) in readers.enumerated() {
            #expect(StackNestFixtures.marker(of: try await reader.value.get().data) == index)
        }
    }

    @Test("出した直後に取り消しても、始める前のタスクを取り消さず、枠は必ず返る（何度繰り返しても枠が減らない）",
          .timeLimit(.minutes(1)))
    func cancelRightAfterLaunchNeverLeaksASlot() async throws {
        let stub = StackNestStubServer(pageCount: 12)
        let session = try makeSession(stub) { $0.maxConcurrentRequests = 1 }
        let record = LaunchRecord()
        // 出した直後（ロックの外）に、その件の待つ人を抜けさせる（先読みの置き換え・閉じる）。ここで取り消しが
        // 始める前のタスクに届くと、完了が知らされるかは `URLSession` 任せになり、枠が戻らないことがある。
        session.setLaunchHookForTesting { key, task in
            record.append(task.state)
            guard case .page(let index, _) = key else { return }
            if index < 10 { session.prefetch([]) } else { session.close() }
        }
        // 枠は 1 つだけなので、1 度でも漏れれば以後の要求は出ない。
        for index in 0..<10 {
            session.prefetch([index])
            #expect(await waitUntil { session.runningCountForTesting == 0 && session.inFlightKeysForTesting.isEmpty },
                    "置き換えで取り消した件の枠が返る（\(index) 回目）")
        }
        let reader = Task { try await session.page(10) }
        await #expect(throws: CancellationError.self) { try await reader.value }
        #expect(await waitUntil { session.runningCountForTesting == 0 }, "閉じて取り消した件の枠も返る")
        session.setLaunchHookForTesting(nil)
        try await session.postProgress(page: 5)
        #expect(stub.requests.last?.route == .progress, "枠が残っているので、閉じた後の書き戻しが出る")
        #expect(record.states.count == 11, "先読み 10 件と、閉じたページ 1 件")
        #expect(!record.states.contains(.suspended), "取り消しうるタスクは、すべて始めた後")
        #expect(session.runningCountForTesting == 0)
    }
}

/// 出した要求のタスクの状態の記録（差し込み口から別のスレッドで書く）。
private final class LaunchRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLSessionTask.State] = []

    func append(_ state: URLSessionTask.State) { lock.withLock { values.append(state) } }
    var states: [URLSessionTask.State] { lock.withLock { values } }
}
