import FakeStackNestServer
import Foundation
import KitProbe
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

/// 本物の 127.0.0.1 のソケットと本物の URLSession で、部品を端から端まで試す。
@Suite("端から端（偽の StackNest）")
struct EndToEndTests {
    private func startServer(pages: Int = 3, configure: (inout FakeStackNestServer.Options) -> Void = { _ in })
        throws -> FakeStackNestServer
    {
        var options = FakeStackNestServer.Options(pages: (0..<pages).map { StackNestFixtures.pngPage(marker: $0) })
        configure(&options)
        let server = FakeStackNestServer(options: options)
        _ = try server.start()
        return server
    }

    private func writeReference(_ reference: StackNestBookReference) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kit-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Fake Book.stacknestbook")
        try reference.encodedJSON().write(to: url)
        return url
    }

    @Test("開く → manifest → ページ → 書き戻し（鍵と kit= 付きの名乗りが届く）")
    func openReadWriteBack() async throws {
        let server = try startServer()
        defer { server.stop() }
        let session = try StackNestBookSession(contentsOf: try writeReference(try server.reference()))
        #expect(try await session.manifest().pageCount == 3)
        #expect(StackNestFixtures.marker(of: try await session.page(1, maxWidth: 100).data) == 1)
        try await session.postProgress(page: 1)
        let records = server.receivedRequests
        #expect(records.map(\.path) == ["manifest", "pages/1?maxw=100", "progress"])
        #expect(records.allSatisfy { $0.authorized })
        #expect(records.allSatisfy { $0.viewer?.contains("; kit=\(StackNestViewerKitInfo.version)") == true })
        #expect(records.last?.progressPage == 1)
        #expect(!String(decoding: try server.recordsJSON(), as: UTF8.self).contains("fake-server-token"))
    }

    @Test("本物のソケットでも、別のポートへのリダイレクトに付いて行かない")
    func realRedirectIsRefused() async throws {
        let elsewhere = try startServer()
        defer { elsewhere.stop() }
        let server = try startServer {
            $0.redirects["manifest"] = "http://127.0.0.1:\(elsewhere.bookURL.port!)/api/v1/libraries/00000000-0000-4000-8000-000000000001/books/1/manifest"
        }
        defer { server.stop() }
        let session = try StackNestBookSession(contentsOf: try writeReference(try server.reference()))
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 302)) { try await session.manifest() }
        #expect(elsewhere.receivedRequests.isEmpty)
    }

    @Test("遅い応答は時間切れで .cannotConnect")
    func slowResponseTimesOut() async throws {
        let server = try startServer { $0.delays["pages/0"] = 5 }
        defer { server.stop() }
        var configuration = StackNestBookSession.Configuration()
        configuration.requestTimeout = .milliseconds(500)
        let session = try StackNestBookSession(contentsOf: try writeReference(try server.reference()),
                                               configuration: configuration)
        let start = Date()
        await #expect(throws: StackNestViewerError(.cannotConnect)) { try await session.page(0) }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test("違う鍵は 401 → .unauthorized")
    func wrongTokenIsUnauthorized() async throws {
        let server = try startServer()
        defer { server.stop() }
        let wrong = try StackNestBookReference(
            version: 1, title: "t", bookURL: server.bookURL, token: "wrong-token", expiresAt: .distantFuture,
            pageCount: 3, direction: .rightToLeft, startPage: 0)
        let session = try StackNestBookSession(contentsOf: try writeReference(wrong))
        await #expect(throws: StackNestViewerError(.unauthorized)) { try await session.manifest() }
        #expect(server.receivedRequests.map(\.authorized) == [false])
    }

    @Test("probe: manifest → 開くページ → progress が通り、JSON に鍵が出ない")
    func probeReportsSuccess() async throws {
        let server = try startServer()
        defer { server.stop() }
        let file = try writeReference(try server.reference(startPage: 2))
        let result = await KitProbe.run(referenceFile: file)
        #expect(result.failure == nil)
        #expect(result.manifestPageCount == 3)
        #expect(result.pageIndex == 2)
        #expect((result.pageBytes ?? 0) > 0)
        #expect(result.pageContentType == "image/png")
        #expect(result.progressPosted)
        #expect(server.receivedRequests.map(\.path) == ["manifest", "pages/2", "progress"])
        #expect(!String(decoding: try KitProbe.json(result), as: UTF8.self).contains("fake-server-token"))
    }

    @Test("probe --no-progress: manifest と開くページだけを読み、書き戻さない")
    func probeWithoutProgressPostsNothing() async throws {
        let server = try startServer()
        defer { server.stop() }
        let file = try writeReference(try server.reference(startPage: 1))
        let result = await KitProbe.run(referenceFile: file, postsProgress: false)
        #expect(result.failure == nil)
        #expect(result.progressRequested == false)
        #expect(result.progressPosted == false)
        #expect(server.receivedRequests.map(\.path) == ["manifest", "pages/1"])
    }

    @Test("probe: loopback でない参照ファイルは、要求を出さずに hostNotAllowed")
    func probeRefusesNonLoopbackReference() async throws {
        let reference = try StackNestBookReference(
            version: 1, title: "t", bookURL: URL(string: "http://192.0.2.1:51234/api/v1/libraries/L/books/1")!,
            token: "t", expiresAt: .distantFuture, pageCount: 3, direction: .rightToLeft, startPage: 0)
        let result = await KitProbe.run(referenceFile: try writeReference(reference))
        #expect(result.failure == "hostNotAllowed")
        #expect(result.manifestPageCount == nil)
    }
}
