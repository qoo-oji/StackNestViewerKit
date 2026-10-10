import Foundation

/// ページ・表紙のバイト列と、応答の `Content-Type`（中身は JPEG・PNG・WebP などのことがある）。
///
/// The bytes of a page or cover and the response's `Content-Type` (JPEG, PNG, WebP and so on).
public struct StackNestPage: Sendable, Equatable {
    public let data: Data
    public let contentType: String?

    public init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType
    }
}

/// 要求の優先度。表示の要求は先読みの列に並ばない。 / Request priority. Display requests never queue behind prefetches.
public enum StackNestRequestPriority: Sendable {
    /// いま表示するページ。 / A page being shown now.
    case display
    /// 先に取っておくページ。 / A page fetched ahead of time.
    case prefetch
}
