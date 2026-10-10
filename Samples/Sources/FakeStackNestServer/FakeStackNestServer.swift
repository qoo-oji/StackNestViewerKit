import Foundation
import Network
import StackNestViewerKitCore

/// 手元で部品を試すための偽の StackNest。127.0.0.1 の本物のソケットで待ち受け、渡したページを本として配る。
/// 受けた要求を記録する（鍵は記録しない。「期待の鍵だったか」だけ）。StackNest を入れていなくても統合を試せる。
///
/// A fake StackNest for trying the kit locally. It listens on a real 127.0.0.1 socket and serves the given
/// pages as a book. Requests are recorded without the token (only whether it matched).
public final class FakeStackNestServer: @unchecked Sendable {
    /// 配る本と振る舞い。 / The book and behaviour.
    public struct Options: Sendable {
        /// ページの画像（番号順）。 / Page images, in order.
        public var pages: [Data]
        /// ページの `Content-Type`（`pageContentTypes` に無いページの既定）。 / The default content type for pages
        /// without an entry in `pageContentTypes`.
        public var contentType = "image/png"
        /// ページごとの `Content-Type`（番号順。足りない分は `contentType`）。表紙は 0 番のページと同じ。
        /// Per-page content types, in order (missing entries use `contentType`). The cover uses page 0's.
        public var pageContentTypes: [String] = []
        /// 受け付ける鍵。 / The accepted token.
        public var token = "fake-server-token"
        public var libraryID = "00000000-0000-4000-8000-000000000001"
        public var bookID = 1
        public var direction = "rtl"
        /// 道（`manifest`・`pages/0` など）ごとの 302 の行き先。 / A 302 target per path suffix.
        public var redirects: [String: String] = [:]
        /// 道ごとに、答える前に待つ秒数。 / Seconds to wait before answering, per path suffix.
        public var delays: [String: TimeInterval] = [:]

        public init(pages: [Data]) { self.pages = pages }

        /// 画像のファイル（番号順）から作る。種類は拡張子から決める（png・jpg・jpeg・webp・gif）。
        /// Builds from image files (in page order); each page's type comes from its file extension.
        public init(imageFiles: [URL]) {
            let loaded = imageFiles.compactMap { url in (try? Data(contentsOf: url)).map { (url, $0) } }
            self.init(pages: loaded.map(\.1))
            pageContentTypes = loaded.map { Self.contentType(forExtension: $0.0.pathExtension) }
        }

        /// 拡張子（大文字小文字を問わない）の `Content-Type`。知らない拡張子は `application/octet-stream`。
        public static func contentType(forExtension fileExtension: String) -> String {
            switch fileExtension.lowercased() {
            case "png": "image/png"
            case "jpg", "jpeg": "image/jpeg"
            case "webp": "image/webp"
            case "gif": "image/gif"
            default: "application/octet-stream"
            }
        }

        /// フォルダの中の画像のファイル（名前の自然順）。 / Image files in a folder, in natural name order.
        public static func imageFiles(in folder: URL) -> [URL] {
            let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
            return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        func contentType(ofPage index: Int) -> String {
            pageContentTypes.indices.contains(index) ? pageContentTypes[index] : contentType
        }
    }

    /// 受けた要求の記録。 / A recorded request.
    public struct Record: Codable, Sendable, Equatable {
        public let method: String
        /// 本の基点の後ろ（`manifest`・`pages/0?maxw=100` など）。基点の外ならパス全体。
        public let path: String
        public let viewer: String?
        public let authorized: Bool
        public let progressPage: Int?
    }

    private let options: Options
    private let queue = DispatchQueue(label: "stacknest-fake-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var records: [Record] = []
    private var boundPort: UInt16 = 0
    private var onRecord: (@Sendable ([Record]) -> Void)?

    public init(options: Options) {
        self.options = options
    }

    deinit {
        listener?.cancel()
    }

    /// 127.0.0.1 の空いているポート（`port` が 0 のとき）で待ち受けを始め、ポートを返す。
    ///
    /// Starts listening on 127.0.0.1 (any free port when `port` is 0) and returns the port.
    public func start(port: UInt16 = 0) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let failure = LockedBox<NWError?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure.set(error)
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
        if let error = failure.get() { throw error }
        let actual = listener.port?.rawValue ?? 0
        lock.withLock {
            self.listener = listener
            boundPort = actual
        }
        return actual
    }

    /// 待ち受けをやめる。 / Stops listening.
    public func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
    }

    /// 本の API の基点。 / The base of the book's API.
    public var bookURL: URL {
        let port = lock.withLock { boundPort }
        return URL(string: "http://127.0.0.1:\(port)/api/v1/libraries/\(options.libraryID)/books/\(options.bookID)")!
    }

    /// この本の参照ファイル。 / A reference for this book.
    public func reference(title: String = "Fake Book", expiresAt: Date = Date().addingTimeInterval(86_400),
                          startPage: Int = 0) throws -> StackNestBookReference
    {
        try StackNestBookReference(
            version: 1, title: title, bookURL: bookURL, token: options.token, expiresAt: expiresAt,
            pageCount: options.pages.count, direction: StackNestReadingDirection(rawValue: options.direction),
            startPage: startPage)
    }

    /// 受けた要求（届いた順）。 / Requests received, in order.
    public var receivedRequests: [Record] { lock.withLock { records } }

    /// 受けた要求を JSON で（鍵は入らない）。 / Received requests as JSON (never contains the token).
    public func recordsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receivedRequests)
    }

    /// 要求を記録するたびに呼ぶ（CLI が記録をファイルへ書き出すため）。
    public func onEveryRecord(_ handler: @escaping @Sendable ([Record]) -> Void) {
        lock.withLock { onRecord = handler }
    }

    // MARK: - 接続

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .request(let request):
                self.respond(to: request, on: connection)
                return
            case .malformed:
                // 解釈できない Content-Length は 400 で閉じる（落ちない）。
                connection.send(content: Self.response(400), completion: .contentProcessed { _ in connection.cancel() })
                return
            case .incomplete:
                break
            }
            if isComplete || error != nil || buffer.count > 1 << 20 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let basePath = "/api/v1/libraries/\(options.libraryID)/books/\(options.bookID)/"
        let suffix = request.target.hasPrefix(basePath) ? String(request.target.dropFirst(basePath.count)) : nil
        let route = suffix.map { $0.split(separator: "?", maxSplits: 1).first.map(String.init) ?? $0 }
        let authorized = request.headers["authorization"] == "Bearer \(options.token)"
        let progressPage = route == "progress"
            ? ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["page"] as? Int : nil
        let record = Record(method: request.method, path: suffix ?? request.target,
                            viewer: request.headers["x-stacknest-viewer"], authorized: authorized,
                            progressPage: progressPage)
        let (all, handler) = lock.withLock { () -> ([Record], (@Sendable ([Record]) -> Void)?) in
            records.append(record)
            return (records, onRecord)
        }
        handler?(all)
        let response = makeResponse(route: route, method: request.method, authorized: authorized)
        let delay = route.flatMap { options.delays[$0] } ?? 0
        queue.asyncAfter(deadline: .now() + delay) {
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func makeResponse(route: String?, method: String, authorized: Bool) -> Data {
        guard let route else { return Self.response(404) }
        guard authorized else { return Self.response(401) }
        if let location = options.redirects[route] { return Self.response(302, headers: ["Location": location]) }
        switch (method, route) {
        case ("GET", "manifest"):
            let body: [String: Any] = ["pageCount": options.pages.count, "direction": options.direction,
                                       "format": "folder", "etag": "fake"]
            return Self.response(200, headers: ["Content-Type": "application/json"],
                                 body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        case ("GET", "cover"):
            guard let first = options.pages.first else { return Self.response(404) }
            return Self.response(200, headers: ["Content-Type": options.contentType(ofPage: 0)], body: first)
        case ("POST", "progress"):
            return Self.response(200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        default:
            if method == "GET", route.hasPrefix("pages/"), let index = Int(route.dropFirst("pages/".count)),
               options.pages.indices.contains(index)
            {
                return Self.response(200, headers: ["Content-Type": options.contentType(ofPage: index)],
                                     body: options.pages[index])
            }
            return Self.response(404)
        }
    }

    private static func response(_ status: Int, headers: [String: String] = [:], body: Data = Data()) -> Data {
        let reason = [200: "OK", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// 受けた HTTP の要求（見出しと、`Content-Length` の分の本文がそろったら作れる）。
struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    enum Parsed {
        case request(HTTPRequest)
        case incomplete
        case malformed
    }

    /// 見出しが揃っていて `Content-Length` が負・数でないなら `.malformed`、本文が足りなければ `.incomplete`。
    static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8)
        else { return .incomplete }
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].lowercased() == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let length = Int(value), length >= 0 else { return .malformed }
        }
        return HTTPRequest(buffer).map(Parsed.request) ?? .incomplete
    }

    init?(_ buffer: Data) {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return nil }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        method = String(requestLine[0])
        target = String(requestLine[1])
        self.headers = headers
        body = Data(buffer[bodyStart..<(bodyStart + length)])
    }
}

/// 小さな値をロックで守る箱。
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
