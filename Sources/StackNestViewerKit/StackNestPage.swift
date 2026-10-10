import Foundation

/// ページ・表紙のバイト列と、応答の `Content-Type`（中身は JPEG・PNG・WebP などのことがある）。
///
/// The bytes of a page or cover and the response's `Content-Type` (JPEG, PNG, WebP and so on).
public struct StackNestPage: Sendable, Equatable {
    /// ページ・表紙のバイト列。 / The raw bytes.
    public let data: Data
    /// 応答の `Content-Type`。無いときは nil。 / The response's `Content-Type`, or nil if absent.
    public let contentType: String?

    /// バイト列と `Content-Type` から作る。 / Creates a page from bytes and a content type.
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
