import Foundation
import StackNestViewerKit

/// 参照ファイルを 1 つ受け取り、部品のセッションで manifest → 開くページ → progress を試した結果。鍵は入らない。
///
/// The result of trying manifest, the start page and progress with the kit's session. Never contains the token.
public struct ProbeResult: Codable, Sendable, Equatable {
    public var referencePath: String
    public var manifestPageCount: Int?
    public var pageIndex: Int?
    public var pageBytes: Int?
    public var pageContentType: String?
    /// progress を送ろうとしたか（`--no-progress` なら false）。 / Whether progress was attempted.
    public var progressRequested = true
    public var progressPosted = false
    /// 失敗したときのエラーのコード（`StackNestViewerError.Code.rawValue`）か種類。 / The failure's code.
    public var failure: String?
    public var seconds: Double = 0
}

public enum KitProbe {
    /// 試す。失敗しても投げず、`failure` に入れて返す。`postsProgress` が false なら書き戻さない（実物の StackNest に
    /// 向けるとき、読書位置の記録を動かさないため）。
    ///
    /// Runs the probe; failures are reported in `failure`. With `postsProgress` false, nothing is written back.
    public static func run(referenceFile: URL, configuration: StackNestBookSession.Configuration = .init(),
                           postsProgress: Bool = true) async -> ProbeResult
    {
        let start = Date()
        var result = ProbeResult(referencePath: referenceFile.path)
        result.progressRequested = postsProgress
        do {
            let session = try StackNestBookSession(contentsOf: referenceFile, configuration: configuration)
            defer { session.close() }
            let manifest = try await session.manifest()
            result.manifestPageCount = manifest.pageCount
            let index = StackNestBookReference.clampedStartPage(session.reference.startPage, pageCount: manifest.pageCount)
            if manifest.pageCount > 0 {
                let page = try await session.page(index)
                result.pageIndex = index
                result.pageBytes = page.data.count
                result.pageContentType = page.contentType
            }
            if postsProgress {
                try await session.postProgress(page: index)
                result.progressPosted = true
            }
        } catch let error as StackNestViewerError {
            result.failure = error.code.rawValue + (error.statusCode.map { " (HTTP \($0))" } ?? "")
        } catch {
            result.failure = String(describing: type(of: error))
        }
        result.seconds = Date().timeIntervalSince(start)
        return result
    }

    /// 結果の JSON。 / The result as JSON.
    public static func json(_ result: ProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(result)
    }
}
