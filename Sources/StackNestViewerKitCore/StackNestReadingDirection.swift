/// 本の読む向き。知らない値は捨てずに持つ（使わない）。
///
/// The reading direction of a book. Unknown values are kept, not used.
public enum StackNestReadingDirection: Sendable, Hashable {
    /// 右から左（`"rtl"`）。 / Right to left (`"rtl"`).
    case rightToLeft
    /// 左から右（`"ltr"`）。 / Left to right (`"ltr"`).
    case leftToRight
    /// 知らない値。 / A value this release doesn't know.
    case unknown(String)

    /// `"rtl"`・`"ltr"` から作る（大文字小文字を区別する）。
    ///
    /// Creates a direction from `"rtl"` or `"ltr"` (case-sensitive).
    public init(rawValue: String) {
        switch rawValue {
        case "rtl": self = .rightToLeft
        case "ltr": self = .leftToRight
        default: self = .unknown(rawValue)
        }
    }

    /// 形式の文書の書き方の値。 / The value as the format document spells it.
    public var rawValue: String {
        switch self {
        case .rightToLeft: return "rtl"
        case .leftToRight: return "ltr"
        case .unknown(let value): return value
        }
    }
}
