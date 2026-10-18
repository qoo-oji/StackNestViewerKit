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
    }

    private let lock = NSLock()
    private let limit: Int
    private let onComplete: @Sendable (Outcome) -> Void
    private var outcome = Outcome()
    /// 申告に合わせて先に確保した大きさ（試験が見る）。
    private var reserved = 0

    init(limit: Int, onComplete: @escaping @Sendable (Outcome) -> Void) {
        self.limit = limit
        self.onComplete = onComplete
    }

    /// 応答の見出しを受ける。申告（`Content-Length`）が上限を超えたら false（1 バイトも受け取らずに断る）。
    func receive(_ response: URLResponse) -> Bool {
        lock.withLock {
            if let http = response as? HTTPURLResponse {
                outcome.statusCode = http.statusCode
                outcome.contentType = http.value(forHTTPHeaderField: "Content-Type")
                outcome.libraryLocked = http.value(forHTTPHeaderField: "X-Library-Locked") == "1"
            }
            guard response.expectedContentLength <= Int64(limit) else {
                outcome.exceededLimit = true
                return false
            }
            // 申告があれば、その大きさを先に確保する（上限以下なのは上で確かめた）。足していくだけだと、育つたびに
            // 確保し直して一時は倍近くを持ち、確保の余りも残る（上限の 64 MiB に近い応答で目立つ）。申告より多く
            // 届いたら（圧縮を解いた本文など）、そこからはふつうに育つ。上限はこれまでどおり受け取った量で見る。
            if response.expectedContentLength > 0 {
                reserved = Int(response.expectedContentLength)
                outcome.data.reserveCapacity(reserved)
            }
            return true
        }
    }

    var reservedCapacityForTesting: Int { lock.withLock { reserved } }

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
            outcome.error = error
            return outcome
        }
        onComplete(finished)
    }
}

/// `URLSession` の delegate。要求ごとの受け皿の表だけを持ち、`StackNestBookSession` を参照しない
/// （`URLSession` は無効化するまで delegate を強く持つので、セッションを持たせると 1 冊ごとに漏れる）。
///
/// 役目は 2 つ: ①リダイレクトに付いて行かない（鍵を別の宛先へ渡さない。3xx はそのまま応答になり、`.httpStatus`
/// で失敗する） ②本文を上限を見ながら受け取る。メソッドは完了ハンドラの形で書く。形が SDK の宣言と食い違うと、
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
