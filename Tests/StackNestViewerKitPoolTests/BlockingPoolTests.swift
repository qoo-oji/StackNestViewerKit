import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

/// 協調スレッドを飽和させる試験だけを置く（同じプロセスのほかの試験を止めてしまうため、別のターゲットにし、
/// 環境変数 `STACKNEST_KIT_POOL_TEST=1` のときだけ走らせる。ふだんの `swift test` では skip）。
@Suite("協調スレッドの飽和")
struct BlockingPoolTests {
    /// 結果を別のスレッドから受け取る箱。
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (succeeded: Bool, seconds: TimeInterval)?
        func set(succeeded: Bool, seconds: TimeInterval) { lock.withLock { value = (succeeded, seconds) } }
        var result: (succeeded: Bool, seconds: TimeInterval)? { lock.withLock { value } }
    }

    /// 同期の関数の中でセマフォを待つ（async の文脈では `wait()` を直接呼べないため）。
    static func park(on semaphore: DispatchSemaphore) { semaphore.wait() }

    @Test("協調スレッドがすべてふさがっていても、専用のスレッドからの同期の読み出しは 1 秒以内に返る",
          .enabled(if: ProcessInfo.processInfo.environment["STACKNEST_KIT_POOL_TEST"] == "1"))
    func blockingReaderProgressesWhilePoolIsSaturated() async throws {
        let stub = StackNestStubServer(pageCount: 3)
        let session = StackNestBookSession(reference: try stub.reference(), configuration: stub.configuration())
        let reader = StackNestBlockingReader(session: session)
        let blockers = ProcessInfo.processInfo.activeProcessorCount
        let release = DispatchSemaphore(value: 0)
        let started = DispatchGroup()
        for _ in 0..<blockers {
            started.enter()
            Task.detached {
                started.leave()
                Self.park(on: release)  // 協調スレッドを 1 本ふさぐ
            }
        }
        // 結果に関わらず、固い時計で必ず解く。GCD のグローバルなキューは、協調スレッドがふさがっている間は
        // 動かないことがある（手元で確かめた）ので、専用のスレッドで数える。
        Thread {
            Thread.sleep(forTimeInterval: 5)
            for _ in 0..<blockers { release.signal() }
        }.start()
        let outcome = Outcome()
        let thread = Thread {
            _ = started.wait(timeout: .now() + 3)
            let begin = Date()
            let page = try? reader.page(0)
            outcome.set(succeeded: page != nil, seconds: Date().timeIntervalSince(begin))
        }
        thread.start()
        // 試験の本体はふさがっている間は何もしない（解かれた後に結果を見る）。
        try await Task.sleep(for: .seconds(6))
        let result = try #require(outcome.result)
        #expect(result.succeeded)
        #expect(result.seconds < 1.0)
    }
}
