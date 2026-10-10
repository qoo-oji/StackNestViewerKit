import Foundation

/// manifest のうち、ビューアが使うもの（ほかの項目は読み飛ばす）。`etag` を optional にするのは、部品を使う
/// 将来のサーバや手元の偽のサーバが付けないことに備えるため（StackNest は manifest に必ず付ける）。部品は ETag を使わない。
///
/// The parts of a manifest a viewer uses (other keys are ignored). `etag` is optional for servers that
/// omit it; the kit doesn't use ETags.
public struct StackNestBookManifest: Sendable, Equatable {
    /// ページ数（正）。 / The page count (authoritative).
    public let pageCount: Int
    /// 読む向き。 / The reading direction.
    public let direction: StackNestReadingDirection?
    /// 本の形式（参考）。 / The book's format (informational).
    public let format: String?
    /// manifest の ETag。 / The manifest's ETag.
    public let etag: String?

    /// 値から作る。 / Creates a manifest from values.
    public init(pageCount: Int, direction: StackNestReadingDirection?, format: String?, etag: String?) {
        self.pageCount = pageCount
        self.direction = direction
        self.format = format
        self.etag = etag
    }

    /// manifest の JSON を読む。読めない・ページ数が整数でない・上限を超えるなら `.invalidResponse`。
    ///
    /// Parses manifest JSON. Throws `.invalidResponse` when it can't be read or the page count is invalid.
    public static func parse(_ data: Data) throws -> StackNestBookManifest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pageCount = JSONValues.integer(root["pageCount"]),
              (0...StackNestFormat.maxPageCount).contains(pageCount)
        else { throw StackNestViewerError(.invalidResponse) }
        return StackNestBookManifest(
            pageCount: pageCount,
            direction: (root["direction"] as? String).map(StackNestReadingDirection.init(rawValue:)),
            format: root["format"] as? String, etag: root["etag"] as? String)
    }
}
