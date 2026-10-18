import Foundation

/// 1 つの要求の応答の受け皿。上限を見ながら本文を受け取る。
final class ResponseSink: @unchecked Sendable {
    struct Outcome: Sendable {
        var statusCode: Int?
        var contentType: String?
        var libraryLocked = false
        var data = Data()
        var error: (any Error)?
        var exceededLimit = false
        /// 2xx でない応答を、見出しだけで打ち切った（本文は受け取らない。打ち切りの失敗は失敗に数えない）。
        var endedAfterHeaders = false
    }

    private let lock = NSLock()
    private let limit: Int
    private let onComplete: @Sendable (Outcome) -> Void
    private var outcome = Outcome()

    init(limit: Int, onComplete: @escaping @Sendable (Outcome) -> Void) {
        self.limit = limit
        self.onComplete = onComplete
    }

    /// 応答の見出しを受ける。申告（`Content-Length`）が上限を超えたら false（1 バイトも受け取らずに断る）。
    /// 2xx でない応答も false: 振り分けに使うのは状態コードと見出しだけで、本文は使わない。上限より先に状態コードを
    /// 見る（大きな本文を申告した 401・404 などが、一時的な「応答が大きすぎる」に化けないように）。
    func receive(_ response: URLResponse) -> Bool {
        lock.withLock {
            if let http = response as? HTTPURLResponse {
                outcome.statusCode = http.statusCode
                outcome.contentType = http.value(forHTTPHeaderField: "Content-Type")
                outcome.libraryLocked = http.value(forHTTPHeaderField: "X-Library-Locked") == "1"
                guard (200..<300).contains(http.statusCode) else {
                    outcome.endedAfterHeaders = true
                    return false
                }
            }
            guard response.expectedContentLength <= Int64(limit) else {
                outcome.exceededLimit = true
                return false
            }
            return true
        }
    }

    /// 受け取った分を足す。合計が上限を超えたら false（呼び出し側が取り消す。申告が無い・偽りのとき）。
    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard !outcome.exceededLimit else { return false }
            outcome.data.append(chunk)
            guard outcome.data.count <= limit else {
                outcome.exceededLimit = true
                outcome.data = Data()
                return false
            }
            return true
        }
    }

    func complete(error: (any Error)?) {
        let finished = lock.withLock { () -> Outcome in
            // 見出しで打ち切った応答の失敗は、こちらが打ち切った取り消し（振り分けは状態コードで済んでいる）。
            outcome.error = outcome.endedAfterHeaders ? nil : error
            return outcome
        }
        onComplete(finished)
    }
}

/// `URLSession` の delegate。要求ごとの受け皿の表だけを持ち、`StackNestBookSession` を参照しない
/// （`URLSession` は無効化するまで delegate を強く持つので、セッションを持たせると 1 冊ごとに漏れる）。
///
/// 役目は 2 つ: ①リダイレクトに付いて行かない（鍵を別の宛先へ渡さない。3xx はそのまま応答になり、`.httpStatus`
/// で失敗する） ②2xx の本文を上限を見ながら受け取る（2xx でない応答は見出しで打ち切る）。メソッドは完了ハンドラの形で書く。形が SDK の宣言と食い違うと、
/// 任意の要求なので黙って呼ばれなくなる（リダイレクトに付いて行く）。試験 `redirectIsRefused` が見張る。
final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: ResponseSink] = [:]

    func register(_ sink: ResponseSink, for task: URLSessionTask) {
        lock.withLock { sinks[task.taskIdentifier] = sink }
    }

    func unregister(_ task: URLSessionTask) {
        lock.withLock { _ = sinks.removeValue(forKey: task.taskIdentifier) }
    }

    private func sink(for task: URLSessionTask) -> ResponseSink? {
        lock.withLock { sinks[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let sink = sink(for: dataTask) else { return completionHandler(.cancel) }
        completionHandler(sink.receive(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let sink = sink(for: dataTask) else { return }
        if !sink.append(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let sink = lock.withLock { sinks.removeValue(forKey: task.taskIdentifier) }
        sink?.complete(error: error)
    }
}
