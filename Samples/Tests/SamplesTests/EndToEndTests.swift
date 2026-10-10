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

    @Test("ホストの設定にプロキシ（死んだポート・除外なし）があっても、プロキシを通らず本物のソケットへ届く")
    func hostProxyIsNotUsed() async throws {
        let server = try startServer()
        defer { server.stop() }
        var configuration = StackNestBookSession.Configuration()
        configuration.requestTimeout = .seconds(5)
        configuration.makeURLSessionConfiguration = {
            let host = URLSessionConfiguration.ephemeral
            // No exceptions key on purpose: with one, loopback would go direct and the test would prove nothing.
            host.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9]
            return host
        }
        let session = try StackNestBookSession(contentsOf: try writeReference(try server.reference()),
                                               configuration: configuration)
        #expect(try await session.manifest().pageCount == 3)
        #expect(server.receivedRequests.map(\.path) == ["manifest"])
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
        // 書き戻すのは開いたページ（3 ページで startPage 2 なので 2）。0 でも他でもない。
        #expect(server.receivedRequests.last?.progressPage == 2)
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

    @Test("probe の引数: --no-progress で書き戻さない。置き場違いと綴り違いは拒む")
    func probeArgumentParsing() {
        #expect(ProbeOptions.parse(["book"])?.postsProgress == true)
        #expect(ProbeOptions.parse(["book", "--no-progress"])?.postsProgress == false)
        #expect(ProbeOptions.parse(["book", "--allow-host", "h"])?.extraHosts == ["h"])
        #expect(ProbeOptions.parse(["--no-progress", "book"]) == nil)
        #expect(ProbeOptions.parse(["book", "--no-progres"]) == nil)
        #expect(ProbeOptions.parse(["book", "--allow-host"]) == nil)
        #expect(ProbeOptions.parse([]) == nil)
    }

    @Test("負の Content-Length は 400 で、落ちずに次の要求へ答える")
    func negativeContentLengthIsRefusedWithoutCrashing() async throws {
        let server = try startServer()
        defer { server.stop() }
        let port = try #require(server.bookURL.port)
        let bad = try rawExchange(port: port, request: "GET /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n")
        #expect(bad.hasPrefix("HTTP/1.1 400"))
        let session = try StackNestBookSession(contentsOf: try writeReference(try server.reference()))
        #expect(try await session.manifest().pageCount == 3)
    }

    /// 127.0.0.1 の本物のソケットへ生の要求を送り、閉じられるまでの応答を文字列で返す。
    private func rawExchange(port: Int, request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0)
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            received.append(contentsOf: chunk[..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }
}
