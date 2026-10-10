import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// ページと表紙: 二重取得の防止・取り消しの意味・キャッシュ・範囲・404 の振り分け・閉じる。
@Suite("セッション: ページ")
struct StackNestSessionPageTests {
    @Test("pages/{n}: 番号のページを Content-Type 付きで返す")
    func pageReturnsTheImageAndContentType() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let session = try makeSession(stub)
        let page = try await session.page(2)
        #expect(StackNestFixtures.marker(of: page.data) == 2)
        #expect(page.contentType == "image/png")
        #expect(stub.requests.map(\.route) == [.page(2)])
    }

    @Test("maxWidth は ?maxw= とキャッシュの鍵に入る。0 以下は付けない")
    func maxWidthIsSentAndKeysTheCache() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let session = try makeSession(stub)
        _ = try await session.page(1, maxWidth: 200)
        _ = try await session.page(1, maxWidth: 200)
        _ = try await session.page(1)
        _ = try await session.page(2, maxWidth: 0)
        _ = try await session.page(3, maxWidth: -5)
        #expect(stub.requests.map(\.maxWidth) == [200, nil, nil, nil])
        #expect(stub.requests.map(\.route) == [.page(1), .page(1), .page(2), .page(3)])
    }

    @Test("表紙も同じ道を通る（鍵・名乗り・?maxw=）")
    func coverUsesTheSamePath() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        let cover = try await session.cover(maxWidth: 300)
        #expect(StackNestFixtures.marker(of: cover.data) == 255)
        let request = try #require(stub.requests.first)
        #expect(request.route == .cover && request.maxWidth == 300)
        #expect(request.carriesExpectedToken && request.viewerHeader == expectedViewerHeader)
    }

    @Test("すべての要求（POST を含む）に鍵と名乗りが付く。format= は常に参照ファイルの版")
    func everyRequestCarriesTokenAndIdentification() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub) {
            $0.identification = StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: "2.0",
                                                               format: 9)
        }
        _ = try await session.manifest()
        _ = try await session.page(0)
        _ = try await session.cover()
        try await session.postProgress(page: 1)
        #expect(stub.requests.count == 4)
        for request in stub.requests {
            #expect(request.carriesExpectedToken)
            #expect(request.viewerHeader == "com.example.viewer/2.0; format=1; kit=\(StackNestViewerKitInfo.version)")
        }
    }

    @Test("期限を過ぎた参照ファイルでは要求を出さない（manifest・pages・cover・progress のどれも）")
    func expiredReferenceMakesNoRequest() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub, expiresAt: Date().addingTimeInterval(-60))
        await #expect(throws: StackNestViewerError(.expired)) { try await session.manifest() }
        await #expect(throws: StackNestViewerError(.expired)) { try await session.page(0) }
        await #expect(throws: StackNestViewerError(.expired)) { try await session.cover() }
        await #expect(throws: StackNestViewerError(.expired)) { try await session.postProgress(page: 1) }
        #expect(stub.requests.isEmpty)
    }

    @Test("同じページを同時に読んでも要求は 1 件で、両方に同じバイト列が返る")
    func concurrentReadsShareOneRequest() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(1))
        defer { gate.open() }
        let session = try makeSession(stub)
        async let first = session.page(1)
        #expect(await gate.arrival())
        async let second = session.page(1)
        #expect(await waitUntil { session.waiterCountForTesting(.page(index: 1, maxWidth: nil)) == 2 })
        gate.open()
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(stub.requestCount(.page(1)) == 1)
    }

    @Test("先に来た待つ人が取り消されても、ほかの待つ人の取得は続く")
    func cancelledFirstWaiterDoesNotFailOthers() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub)
        let first = Task { try await session.page(0) }
        #expect(await gate.arrival())
        let second = Task { try await session.page(0) }
        #expect(await waitUntil { session.waiterCountForTesting(.page(index: 0, maxWidth: nil)) == 2 })
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        gate.open()
        #expect(StackNestFixtures.marker(of: try await second.value.data) == 0)
        #expect(stub.requestCount(.page(0)) == 1)
        // URLSession's clean-up stop arrives shortly after delivery; it must not be counted as a cancellation.
        try await Task.sleep(for: .milliseconds(200))
        #expect(stub.stoppedRequestCount == 0)
    }

    @Test("最後の待つ人が取り消されたら、要求も取り消す")
    func lastWaiterCancellationCancelsTheRequest() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub)
        let only = Task { try await session.page(0) }
        #expect(await gate.arrival())
        only.cancel()
        await #expect(throws: CancellationError.self) { try await only.value }
        #expect(await waitUntil { stub.stoppedRequestCount == 1 })
        #expect(session.inFlightKeysForTesting.isEmpty)
    }

    @Test("取ったページは持ち、同じページは取りに行かない。枚数で古いものから捨てる")
    func cacheEvictsByCountAndBytes() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        let session = try makeSession(stub) { $0.pageCacheCount = 2 }
        for index in [0, 1, 0, 2, 0, 1] { _ = try await session.page(index) }
        // 0 1 (0 は持っている) 2 → 1 を捨てる (0 は持っている) 1 → 取り直す
        #expect(stub.requests.map(\.route) == [.page(0), .page(1), .page(2), .page(1)])
        #expect(session.cachedKeysForTesting == [.page(index: 0, maxWidth: nil), .page(index: 1, maxWidth: nil)])
    }

    @Test("1 枚が予算の半分を超えるページは持たない")
    func oversizedPageIsNotCached() async throws {
        let stub = StackNestStubServer(pageCount: 4)
        stub.respond(.page(0), with: .status(200, body: Data(count: 600)))
        stub.respond(.page(1), with: .status(200, body: Data(count: 400)))
        let session = try makeSession(stub) { $0.pageCacheBytes = 1000 }
        _ = try await session.page(0)
        _ = try await session.page(0)
        _ = try await session.page(1)
        _ = try await session.page(1)
        #expect(stub.requests.map(\.route) == [.page(0), .page(0), .page(1)])
    }

    @Test("負の番号は要求なしで .pageOutOfRange（既知のページ数が入る）")
    func outOfRangeMakesNoRequest() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 3)) { try await session.page(-1) }
        #expect(stub.requests.isEmpty)
    }

    @Test("既知のページ数以上は、manifest を 1 度だけ読み直し、なお外なら要求なしで .pageOutOfRange")
    func outOfRangeRereadsManifestOnce() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 3)) { try await session.page(3) }
        #expect(stub.requestCount(.manifest) == 1)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 3)) { try await session.page(999) }
        #expect(stub.requestCount(.manifest) == 1)
        #expect(stub.requests.allSatisfy { $0.route == .manifest })
    }

    @Test("参照ファイルより後に増えたページは、確かめ直しで届く")
    func pagesAddedSinceTheFileWasWrittenAreReached() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        stub.setPageCount(12)
        #expect(StackNestFixtures.marker(of: try await session.page(9).data) == 9)
        #expect(stub.requests.map(\.route) == [.manifest, .page(9)])
    }

    @Test("範囲内の 404 は manifest を読み直して振り分ける（本が無い・ページ数が減った・それ以外）")
    func pageNotFoundIsClassified() async throws {
        let gone = StackNestStubServer(pageCount: 3)
        gone.respond(.page(1), with: .status(404))
        gone.respond(.manifest, with: .status(404))
        await #expect(throws: StackNestViewerError(.bookNotFound)) { try await makeSession(gone).page(1) }

        let shrunk = StackNestStubServer(pageCount: 3)
        let session = try makeSession(shrunk)
        shrunk.setPageCount(1)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 1)) { try await session.page(2) }
        #expect(shrunk.requests.map(\.route) == [.page(2), .manifest])

        let odd = StackNestStubServer(pageCount: 3)
        odd.respond(.page(1), with: .status(404))
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 404)) { try await makeSession(odd).page(1) }
    }

    @Test("404 の後の manifest の読み直しが失敗したら、その失敗をそのまま返す（StackNest の終了・期限切れが見える）")
    func rereadFailuresAreReturnedAsIs() async throws {
        let stopped = StackNestStubServer(pageCount: 3)
        stopped.respond(.page(1), with: .status(404))
        stopped.respond(.manifest, with: .failure(.cannotConnectToHost))
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await makeSession(stopped).page(1) }

        let revoked = StackNestStubServer(pageCount: 3)
        revoked.respond(.page(1), with: .status(404))
        revoked.respond(.manifest, with: .status(401))
        await #expect(throws: StackNestViewerError(.unauthorized)) { try await makeSession(revoked).page(1) }
    }

    @Test("manifest でページ数が減ったら、範囲の外になったページのキャッシュを捨て、要求なしで .pageOutOfRange")
    func shrunkManifestEvictsStalePages() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        for index in 0..<3 { _ = try await session.page(index) }
        stub.setPageCount(1)
        _ = try await session.manifest(refresh: true)
        #expect(session.cachedKeysForTesting == [.page(index: 0, maxWidth: nil)])
        let before = stub.requests.count
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 1)) { try await session.page(2) }
        #expect(stub.requests.count == before)
    }

    @Test("中継のキャッシュの道: ETag の無いページの応答でも読み、形式は Content-Type で分かる")
    func pageResponseWithoutETag() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        stub.respond(.page(0), with: .status(200, headers: ["Content-Type": "image/jpeg"], body: Data([1, 2, 3])))
        let session = try makeSession(stub)
        #expect(try await session.page(0) == StackNestPage(data: Data([1, 2, 3]), contentType: "image/jpeg"))
    }

    @Test("中継の 502 は一時的な .remoteUnavailable（先読みも書き戻しも止めない）")
    func relay502IsTransient() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        stub.respond(.page(1), with: .status(502))
        let session = try makeSession(stub)
        do {
            _ = try await session.page(1)
            Issue.record("502 で失敗しなかった")
        } catch let error as StackNestViewerError {
            #expect(error.code == .remoteUnavailable)
            #expect(!error.isPermanent)
        }
        stub.respond(.page(1), with: .status(200, body: Data([9])))
        #expect(try await session.page(1).data == Data([9]))
        session.prefetch([2])
        #expect(await waitUntil { stub.requestCount(.page(2)) == 1 }, "恒久的な失敗ではないので先読みは続く")
    }

    @Test("閉じると、待っているページは取り消しで戻り、以後は書き戻しのほかすべて要求なしで失敗する（覚えた manifest も返さない）")
    func closeStopsPagesButNotProgress() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub)
        _ = try await session.manifest()
        _ = try await session.page(1)
        let waiting = Task { try await session.page(0) }
        #expect(await gate.arrival())
        session.close()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(session.cachedKeysForTesting.isEmpty)
        let before = stub.requests.count
        await #expect(throws: CancellationError.self) { try await session.page(1) }
        await #expect(throws: CancellationError.self) { try await session.manifest() }
        await #expect(throws: CancellationError.self) { try await session.manifest(refresh: true) }
        await #expect(throws: CancellationError.self) { try await session.cover() }
        await #expect(throws: CancellationError.self) { try await session.page(-1) }
        await #expect(throws: CancellationError.self) { try await session.page(3) }
        #expect(stub.requests.count == before)
        try await session.postProgress(page: 2)
        #expect(stub.requests.last?.progressPage == 2)
    }
}

@Suite("キャッシュの単体")
struct PageCacheTests {
    private func response(_ bytes: Int) -> FetchedResponse { FetchedResponse(data: Data(count: bytes), contentType: nil) }
    private func key(_ index: Int) -> RequestKey { .page(index: index, maxWidth: nil) }

    @Test("合計の大きさが予算を超えたら古いものから捨て、読み直したものは新しい側へ回る")
    func evictsOldestByBytes() {
        var cache = PageCache(capacity: 8, byteBudget: 100)
        cache.store(response(40), for: key(0))
        cache.store(response(40), for: key(1))
        #expect(cache.value(for: key(0)) != nil)
        cache.store(response(40), for: key(2))
        #expect(cache.keys == [key(0), key(2)])
        cache.store(response(40), for: key(3))
        #expect(cache.keys == [key(2), key(3)])
    }

    @Test("半分を超えるページは持たず、持っていた同じ鍵の古い値も残さない")
    func skipsOversizedPage() {
        var cache = PageCache(capacity: 8, byteBudget: 100)
        cache.store(response(30), for: key(0))
        cache.store(response(50), for: key(1))
        cache.store(response(51), for: key(2))
        #expect(cache.keys == [key(0), key(1)])
        cache.store(response(51), for: key(0))
        #expect(cache.keys == [key(1)])
    }
}
