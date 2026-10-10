import Foundation
import StackNestViewerKitTesting
import Testing

@testable import StackNestViewerKit

/// セッションの 1 本の道: 鍵と名乗り・失敗の振り分け・リダイレクトの拒否・本文の上限・宛先の制限・期限・寿命。
@Suite("セッション: 要求の道")
struct StackNestSessionRequestTests {
    @Test("manifest: 基点の後ろの manifest を、鍵と名乗り（kit= 付き）を付けて GET する")
    func manifestCarriesTokenAndViewerHeader() async throws {
        let stub = StackNestStubServer(pageCount: 9)
        let session = try makeSession(stub)
        let manifest = try await session.manifest()
        #expect(manifest == StackNestBookManifest(pageCount: 9, direction: .rightToLeft, format: "archive", etag: "stub"))
        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        #expect(request.route == .manifest)
        #expect(request.carriesExpectedToken)
        #expect(request.viewerHeader == expectedViewerHeader)
        #expect(request.viewerHeader?.hasSuffix("; format=1; kit=\(StackNestViewerKitInfo.version)") == true)
    }

    @Test("manifest は読んだものを使い回し、refresh: true で読み直す")
    func manifestIsReusedUntilRefreshed() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = try makeSession(stub)
        _ = try await session.manifest()
        _ = try await session.manifest()
        #expect(stub.requestCount(.manifest) == 1)
        stub.setPageCount(5)
        #expect(try await session.manifest(refresh: true).pageCount == 5)
        #expect(stub.requestCount(.manifest) == 2)
    }

    @Test("progress: {\"page\": n} を JSON で POST し、鍵と名乗りを付ける")
    func progressPostsJSON() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        try await session.postProgress(page: 4)
        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.route == .progress)
        #expect(request.progressPage == 4)
        #expect(request.carriesExpectedToken)
        #expect(request.viewerHeader == expectedViewerHeader)
    }

    @Test("負のページの書き戻しは要求を出さずに .pageOutOfRange")
    func negativeProgressMakesNoRequest() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 3)) { try await session.postProgress(page: -1) }
        #expect(stub.requests.isEmpty)
    }

    static let failureCases: [(StackNestStubServer.Response, StackNestViewerError)] = [
        (.status(401), StackNestViewerError(.unauthorized)),
        (.status(403, headers: ["X-Library-Locked": "1"]), StackNestViewerError(.libraryLocked)),
        (.status(403), StackNestViewerError(.unauthorized)),
        (.status(404), StackNestViewerError(.bookNotFound)),
        (.status(500), StackNestViewerError(.httpStatus, statusCode: 500)),
        (.status(502), StackNestViewerError(.remoteUnavailable)),
        (.failure(.cannotConnectToHost), StackNestViewerError(.cannotConnect)),
        (.failure(.timedOut), StackNestViewerError(.cannotConnect)),
        (.failure(.appTransportSecurityRequiresSecureConnection), StackNestViewerError(.insecureConnectionBlocked)),
    ]

    @Test("応答と通信の失敗を、エラーのコードに振り分ける", arguments: failureCases)
    func failureMapping(response: StackNestStubServer.Response, expected: StackNestViewerError) async throws {
        let stub = StackNestStubServer()
        stub.respond(.manifest, with: response)
        let session = try makeSession(stub)
        await #expect(throws: expected) { try await session.manifest() }
    }

    static let routeFailureCases: [(StackNestStubServer.Route, Int, StackNestViewerError)] = [
        (.progress, 404, StackNestViewerError(.bookNotFound)),
        (.progress, 401, StackNestViewerError(.unauthorized)),
        (.cover, 404, StackNestViewerError(.httpStatus, statusCode: 404)),
        (.cover, 401, StackNestViewerError(.unauthorized)),
    ]

    @Test("要求の種類ごとの振り分け（進捗の 404 は本が無い。表紙の 404 は本が無いとは限らない）", arguments: routeFailureCases)
    func routeFailureMapping(route: StackNestStubServer.Route, status: Int, expected: StackNestViewerError) async throws {
        let stub = StackNestStubServer()
        stub.respond(route, with: .status(status))
        let session = try makeSession(stub)
        await #expect(throws: expected) {
            if route == .progress { try await session.postProgress(page: 1) } else { _ = try await session.cover() }
        }
    }

    @Test("manifest の JSON が読めなければ .invalidResponse")
    func brokenManifest() async throws {
        let stub = StackNestStubServer()
        stub.respond(.manifest, with: .status(200, body: Data("not json".utf8)))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.invalidResponse)) { try await session.manifest() }
    }

    @Test("リダイレクトには付いて行かない（鍵を別の宛先へ渡さない）。3xx は .httpStatus")
    func redirectIsRefused() async throws {
        let stub = StackNestStubServer()
        let elsewhere = URL(string: "http://127.0.0.1:2/api/v1/libraries/\(stub.bookURL.pathComponents[4])/elsewhere")!
        stub.respond(.manifest, with: .redirect(to: elsewhere))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 302)) { try await session.manifest() }
        #expect(stub.requests.count == 1)
        #expect(stub.requests.allSatisfy { $0.url.port == 51234 })
    }

    @Test("同じ宛先へのリダイレクトにも付いて行かない")
    func sameOriginRedirectIsRefused() async throws {
        let stub = StackNestStubServer()
        stub.respond(.manifest, with: .redirect(to: stub.bookURL.appendingPathComponent("pages/0")))
        let session = try makeSession(stub)
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 302)) { try await session.manifest() }
        #expect(stub.requests.count == 1)
    }

    @Test("本文の上限: Content-Length の申告が超えたら受け取らずに .responseTooLarge")
    func contentLengthOverCap() async throws {
        let stub = StackNestStubServer()
        stub.respond(.progress, with: .status(200, headers: ["Content-Length": "5000"], body: Data(count: 10)))
        let session = try makeSession(stub) { $0.maxResponseBytes = 1000 }
        await #expect(throws: StackNestViewerError(.responseTooLarge)) { try await session.postProgress(page: 1) }
    }

    @Test("本文の上限: 申告が無く、受け取った量が超えたら .responseTooLarge。上限ちょうどは通る")
    func streamedBodyOverCap() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub) { $0.maxResponseBytes = 1000 }
        stub.respond(.progress, with: .status(200, body: Data(count: 1001)))
        await #expect(throws: StackNestViewerError(.responseTooLarge)) { try await session.postProgress(page: 1) }
        stub.respond(.progress, with: .status(200, body: Data(count: 1000)))
        try await session.postProgress(page: 2)
        #expect(StackNestBookSession.Configuration().maxResponseBytes == 64 * 1024 * 1024)
    }

    @Test("要求の URL は基点の後ろへ文字列で足す（IPv6 の区域 ID・末尾のスラッシュでも同じ宛先のまま）")
    func ipv6ZoneEndpoint() throws {
        let book = URL(string: "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7/")!
        let reference = try StackNestBookReference(version: 1, title: "t", bookURL: book, token: "t",
                                                   expiresAt: .distantFuture, pageCount: 9, direction: .rightToLeft,
                                                   startPage: 0)
        let session = StackNestBookSession(reference: reference)
        #expect(session.makeRequest(for: .page(index: 3, maxWidth: 200))?.url?.absoluteString
                == "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7/pages/3?maxw=200")
        #expect(session.makeRequest(for: .manifest)?.url?.absoluteString
                == "http://[fe80::1%25en0]:51234/api/v1/libraries/L/books/7/manifest")
        let post = session.makeRequest(for: .progress(serial: 1, page: 5))
        #expect(post?.httpMethod == "POST")
        #expect(post?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(post?.httpBody == Data(#"{"page":5}"#.utf8))
        #expect(post?.timeoutInterval == 20)
    }

    @Test("loopback でない book には要求を 1 件も出さずに .hostNotAllowed")
    func nonLoopbackBookMakesNoRequest() async throws {
        let stub = StackNestStubServer()
        let session = StackNestBookSession(reference: try reference(stub, host: "192.0.2.1"),
                                           configuration: stub.configuration())
        await #expect(throws: StackNestViewerError(.hostNotAllowed)) { try await session.manifest() }
        await #expect(throws: StackNestViewerError(.hostNotAllowed)) { try await session.postProgress(page: 1) }
        #expect(stub.requests.isEmpty)
    }

    @Test("明示して広げたホストにはつなぐ。::1 は既定で通る")
    func widenedPolicyAllowsListedHost() async throws {
        let stub = StackNestStubServer()
        var configuration = stub.configuration()
        configuration.allowedHosts = .loopback(plus: ["192.0.2.1"])
        let widened = StackNestBookSession(reference: try reference(stub, host: "192.0.2.1"), configuration: configuration)
        _ = try await widened.manifest()
        let ipv6 = StackNestBookSession(reference: try reference(stub, host: "[::1]"), configuration: stub.configuration())
        _ = try await ipv6.manifest()
        #expect(stub.requestCount(.manifest) == 2)
    }

    @Test("init(contentsOf:) は loopback でない book を開く時点で断る")
    func contentsOfRefusesNonLoopbackBook() throws {
        let stub = StackNestStubServer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lan = try StackNestFixtures.writeReference(
            StackNestFixtures.referenceJSON(bookURL: URL(string: "http://192.0.2.1:51234/api/v1/libraries/L/books/1")!),
            in: folder, title: "Lan")
        #expect(throws: StackNestViewerError(.hostNotAllowed)) {
            _ = try StackNestBookSession(contentsOf: lan, configuration: stub.configuration())
        }
        let local = try StackNestFixtures.writeReference(StackNestFixtures.referenceJSON(bookURL: stub.bookURL), in: folder)
        let session = try StackNestBookSession(contentsOf: local, configuration: stub.configuration())
        #expect(session.reference.bookURL == stub.bookURL)
        #expect(stub.requests.isEmpty, "作るだけでは通信しない")
    }

    @Test("読んでいる途中に期限が来たら、その時点から要求を出さない")
    func expiryIsCheckedOnEveryRequest() async throws {
        let stub = StackNestStubServer()
        let expiresAt = Date().addingTimeInterval(3600)
        let session = try makeSession(stub, expiresAt: expiresAt) { $0.now = { expiresAt } }
        await #expect(throws: StackNestViewerError(.expired)) { try await session.manifest() }
        await #expect(throws: StackNestViewerError(.expired)) { try await session.postProgress(page: 1) }
        #expect(stub.requests.isEmpty)
    }

    @Test("URLSession はキャッシュ・クッキー・資格情報の保管を持たず、つながるのを待たない")
    func sessionHasNoPersistentStores() throws {
        let stub = StackNestStubServer()
        let host = URLSessionConfiguration.default
        host.protocolClasses = [] // 何を返しても外す
        // A host-supplied proxy (dead port) must not survive hardening.
        host.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9]
        let session = try makeSession(stub) { $0.makeURLSessionConfiguration = { host } }
        // ホストの設定は書き換えない（コピーに手を入れる）。
        #expect(host.urlCache != nil)
        #expect(host.httpCookieStorage != nil)
        #expect(host.connectionProxyDictionary?.isEmpty == false)
        #expect(host.timeoutIntervalForResource == URLSessionConfiguration.default.timeoutIntervalForResource)
        let configuration = session.urlSessionConfigurationForTesting
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true, "プロキシは使わない（鍵は book の宛先にだけ送る）")
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForResource == 30, "waitLimit 25 秒＋上乗せ 5 秒（待つ人のいない先読みの歯止め）")
    }

    @Test("async の顔も waitLimit で必ず戻る（要求の資源の時間切れより先に、待つ人の時計が効く）", .timeLimit(.minutes(1)))
    func asyncWaitLimitIsEnforced() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.waitLimit = .milliseconds(300) }
        let start = Date()
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await session.page(0) }
        // 資源の時間切れは 5.3 秒。1.5 秒より早く戻るのは、待つ人の時計が効いたから。
        #expect(Date().timeIntervalSince(start) < 1.5)
        #expect(await waitUntil { stub.stoppedRequestCount == 1 }, "最後の待つ人が抜けたので要求も取り消す")
        #expect(session.ticketCountForTesting == 0)
    }

    @Test("時計は待つ人ごとに、その呼び出しから数える（先に来た人の時間切れで、後の人は失敗しない）", .timeLimit(.minutes(1)))
    func waitLimitCountsFromEachCall() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let gate = stub.gate(.page(0))
        defer { gate.open() }
        let session = try makeSession(stub) { $0.waitLimit = .milliseconds(600) }
        let first = Task { try await session.page(0) }
        #expect(await gate.arrival())
        try await Task.sleep(for: .milliseconds(400))
        let second = Task { try await session.page(0) }
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await first.value }
        #expect(session.waiterCountForTesting(.page(index: 0, maxWidth: nil)) == 1, "後の人はまだ待っている")
        gate.open()
        #expect(StackNestFixtures.marker(of: try await second.value.data) == 0)
    }

    @Test("古い件の manifest の応答が後から記録されても、新しい manifest は残る")
    func olderManifestResponseDoesNotOverwriteNewer() async throws {
        let stub = StackNestStubServer(pageCount: 10)
        let session = try makeSession(stub)
        let older = try await session.fetch(.manifest, priority: .display)
        stub.setPageCount(4)
        #expect(try await session.manifest(refresh: true).pageCount == 4)
        // 先に取った（件の古い）応答が最後に記録される。呼んだ人には読んだ値が返るが、状態は戻らない。
        #expect(try session.recordManifest(older).pageCount == 10)
        #expect(session.knownPageCountForTesting == 4)
        #expect(session.cachedManifest?.pageCount == 4)
        await #expect(throws: StackNestViewerError(.pageOutOfRange, pageCount: 4)) { try await session.page(7) }
    }

    @Test("見立てを作って返すだけの補助関数で作ったセッションでも通信できる（セッションが見立てを持つ）")
    func sessionKeepsItsStubAlive() async throws {
        func sessionOnly() throws -> StackNestBookSession {
            let stub = StackNestStubServer(pageCount: 4)
            return StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        }
        let session = try sessionOnly()
        #expect(StackNestFixtures.marker(of: try await session.page(2).data) == 2)
    }

    @Test("marker(of:) は Data の一部（スライス）からも読め、見立ての参照ファイルは direction: に従う")
    func markerReadsSlicesAndReferenceHonoursDirection() throws {
        let png = StackNestFixtures.pngPage(marker: 77)
        let padded = Data(repeating: 0, count: 50) + png
        #expect(StackNestFixtures.marker(of: padded[50...]) == 77)
        #expect(StackNestFixtures.marker(of: png) == 77)
        #expect(try StackNestStubServer(direction: "ltr").reference().direction == .leftToRight)
        #expect(try StackNestStubServer().reference().direction == .rightToLeft)
        #expect(try StackNestStubServer(direction: "vertical").reference().direction == .unknown("vertical"))
    }

    @Test("同じ manifest を同時に読んでも、要求は 1 件")
    func concurrentManifestReadsShareOneRequest() async throws {
        let stub = StackNestStubServer()
        let gate = stub.gate(.manifest)
        defer { gate.open() }
        let session = try makeSession(stub)
        async let first = session.manifest(refresh: true)
        #expect(await gate.arrival())
        async let second = session.manifest(refresh: true)
        #expect(await waitUntil { session.waiterCountForTesting(.manifest) == 2 })
        gate.open()
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(stub.requestCount(.manifest) == 1)
    }

    @Test("加わる前に取り消された待つ人は、要求を出さずに 1 度だけ取り消しで戻る", .timeLimit(.minutes(1)))
    func cancelBeforeRegistrationResumesOnce() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        for _ in 0..<200 {
            let task = Task {
                // 取り消しが先に届くまで待ってから呼ぶ（onCancel が登録より先に走る形）。
                while !Task.isCancelled { await Task.yield() }
                return try await session.manifest(refresh: true)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(stub.requests.isEmpty)
        #expect(session.ticketCountForTesting == 0, "札が残らない")
    }

    @Test("完了と取り消しが競っても、待つ人は 1 度だけ戻る（二重の再開で落ちない・取りこぼしで止まらない）",
          .timeLimit(.minutes(1)))
    func completionAndCancellationRaceResumesOnce() async throws {
        let stub = StackNestStubServer()
        let session = try makeSession(stub)
        var outcomes = (succeeded: 0, cancelled: 0)
        for round in 0..<300 {
            let task = Task { try await session.manifest(refresh: true) }
            if round % 3 != 0 { try? await Task.sleep(nanoseconds: UInt64.random(in: 0...300_000)) }
            task.cancel()
            switch await task.result {
            case .success: outcomes.succeeded += 1
            case .failure(let error):
                #expect(error is CancellationError, "\(error)")
                outcomes.cancelled += 1
            }
        }
        #expect(outcomes.succeeded + outcomes.cancelled == 300)
        #expect(await waitUntil { session.ticketCountForTesting == 0 && session.inFlightKeysForTesting.isEmpty })
    }

    @Test("閉じて手放したセッションは解放され、URLSession も delegate を手放す（1 冊ごとに漏れない）")
    func sessionIsReleasedAfterClose() async throws {
        let stub = StackNestStubServer()
        let sessionRef: WeakBox
        let delegateRef: WeakBox
        do {
            let session = try makeSession(stub)
            _ = try await session.manifest()
            session.close()
            sessionRef = WeakBox(session)
            delegateRef = WeakBox(session.delegateForTesting)
        }
        #expect(await waitUntil { sessionRef.isReleased })
        #expect(await waitUntil { delegateRef.isReleased }, "invalidateAndCancel で delegate が手放される")
    }
}
