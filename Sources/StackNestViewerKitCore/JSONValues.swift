import Foundation

/// 参照ファイルと manifest の JSON の値の読み方（形式の文書の約束を 1 か所に置く）。
enum JSONValues {
    /// 整数として読む絶対値の上限（これ未満）。作る側の検査も同じ値を使う。
    static let integerCeiling = 1e15

    /// JSON の整数。真偽値（`NSNumber` で来る）と整数でない数は整数とみなさない
    /// （`"version": true` を版 1 と読まない）。`1.0` のように小数点付きでも値が整数なら読む。
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < integerCeiling else { return nil }
        return number.intValue
    }

    /// ISO 8601 の日時。StackNest は UTC の `Z`・小数秒なしで書くが、小数秒とオフセット付きも読む。
    /// 時差の無い形（`2027-01-15T08:00:00`）は読まない（どの時刻か決まらないため）。
    static func date(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }
}
