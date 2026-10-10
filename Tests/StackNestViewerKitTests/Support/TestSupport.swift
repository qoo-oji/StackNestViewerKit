import Foundation
import StackNestViewerKitTesting

@testable import StackNestViewerKit

/// 条件が成り立つまで（最長 `timeout` 秒）待つ。成り立てば true。
func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// `body` を専用のスレッドで走らせ、結果を待つ（同期の顔を協調スレッドの外で呼ぶため）。
func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.start()
    }
}

/// 見立てに向けたセッション（設定を少し変えたいときは `adjust` で）。
func makeSession(_ stub: StackNestStubServer, expiresAt: Date = .distantFuture, startPage: Int = 0,
                 adjust: (inout StackNestBookSession.Configuration) -> Void = { _ in }) throws -> StackNestBookSession
{
    var configuration = stub.configuration()
    adjust(&configuration)
    return StackNestBookSession(reference: try stub.reference(expiresAt: expiresAt, startPage: startPage),
                                configuration: configuration)
}

/// 別の宛先（`host`）を基点にした、見立てに届く参照ファイル（見立ては `libraries/<ID>` で振り分けるので、
/// もし要求が出れば記録に残る）。
func reference(_ stub: StackNestStubServer, host: String) throws -> StackNestBookReference {
    let url = URL(string: stub.bookURL.absoluteString.replacingOccurrences(of: "127.0.0.1", with: host))!
    return try StackNestBookReference(version: 1, title: "Fixture", bookURL: url, token: "fixture-token",
                                      expiresAt: .distantFuture, pageCount: 3, direction: .rightToLeft, startPage: 0)
}

/// 期待の名乗り（このプロセスの Bundle.main・format=1・kit=部品の版）。
var expectedViewerHeader: String {
    StackNestViewerIdentification.forMainBundle(format: 1).headerValue
}

/// 弱い参照の箱（解放されたかを別のスレッドから見る）。
final class WeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: AnyObject?

    init(_ value: AnyObject?) { self.value = value }

    var isReleased: Bool { lock.withLock { value == nil } }
}
