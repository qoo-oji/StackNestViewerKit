import Foundation

/// ビューアの名乗り `X-StackNest-Viewer: <bundle id>/<版>; format=<版>; kit=<部品の版>`。送る側（部品）と
/// 受ける側（StackNest のサーバ）が、文字種と長さを同じ 1 組の定数で扱う。引数の順は format → kit で固定
/// （受ける側の 200 文字の切り詰めが `format=` を落とさないように）。
///
/// The viewer identification header. Sender (the kit) and receiver (StackNest's server) share one set of
/// character and length rules. Parameters are always in `format`, `kit` order.
public struct StackNestViewerIdentification: Sendable, Hashable {
    /// ヘッダの名前。 / The header name.
    public static let headerName = "X-StackNest-Viewer"
    /// 受ける側が保存する最長の文字数。 / The longest value the receiver stores.
    public static let maxStoredLength = 200
    /// bundle id とビューアの版の長さの上限。 / The length limit of the bundle ID and the viewer version.
    public static let maxComponentLength = 64
    /// 部品の版の長さの上限。 / The length limit of the kit version.
    public static let maxKitVersionLength = 16
    /// bundle id・版・部品の版に使える文字。 / Characters allowed in the bundle ID and versions.
    public static let componentCharacters = "[A-Za-z0-9._+-]"

    /// ビューアの bundle id。 / The viewer's bundle ID.
    public let bundleIdentifier: String
    /// ビューアの版（無ければ nil）。 / The viewer's version, or nil.
    public let version: String?
    /// 読む参照ファイルの版（無ければ nil）。 / The reference file version, or nil.
    public let format: Int?
    /// 部品の版 `kit=`（無ければ nil）。 / The kit version (`kit=`), or nil.
    public let kitVersion: String?

    /// 名乗りを作る。`kitVersion` の既定は、この部品の版。
    ///
    /// Creates an identification. `kitVersion` defaults to this kit's own version.
    public init(bundleIdentifier: String, version: String?, format: Int?,
                kitVersion: String? = StackNestViewerKitInfo.version)
    {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.format = format
        self.kitVersion = kitVersion
    }

    /// このアプリ（`Bundle.main`）の名乗り。 / The identification of this app (`Bundle.main`).
    public static func forMainBundle(format: Int) -> StackNestViewerIdentification {
        StackNestViewerIdentification(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            format: format)
    }

    /// 送る側の値。各部分を `[A-Za-z0-9._+-]` に整え（ほかの文字は `_`）、bundle id と版は 64 文字・部品の版は
    /// 16 文字で切る。改行によるヘッダの注入と、区切り（`/`・`;`）との紛れを防ぐ。最長でも 200 文字に収まる。
    ///
    /// The value to send. Each part is reduced to `[A-Za-z0-9._+-]` (others become `_`) and cut to 64
    /// characters (16 for the kit version), which prevents header injection and separator confusion.
    public var headerValue: String {
        var value = Self.sanitizedComponent(bundleIdentifier, limit: Self.maxComponentLength) ?? "unknown"
        if let version, let cleaned = Self.sanitizedComponent(version, limit: Self.maxComponentLength) {
            value += "/" + cleaned
        }
        if let format { value += "; format=\(format)" }
        if let kitVersion, let cleaned = Self.sanitizedComponent(kitVersion, limit: Self.maxKitVersionLength) {
            value += "; kit=" + cleaned
        }
        return value
    }

    /// 受ける側の保存の形: 印字できる ASCII（0x20〜0x7E）だけを残し、前後の空白を落とし、200 文字で切る。空なら nil。
    ///
    /// The receiver's stored form: printable ASCII only, trimmed, cut at 200 characters; nil when empty.
    public static func sanitizeForStorage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var kept = String.UnicodeScalarView()
        var count = 0
        for scalar in raw.unicodeScalars where scalar.value >= 0x20 && scalar.value <= 0x7E {
            kept.append(scalar)
            count += 1
            if count >= maxStoredLength { break }
        }
        let text = String(kept).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// 名乗りを読む（保存の形に整えてから）。bundle id は `componentCharacters` で検査し、版は 64 文字で切る。
    /// `;` で区切った `key=value` のうち `format=`・`kit=` だけを読み、ほかは読み飛ばす。`kit=` が無くても読める
    /// （`kitVersion` が nil になる）。`headerValue` が出す値は必ず読める。
    ///
    /// Parses an identification (after storage sanitizing). Only `format=` and `kit=` parameters are read;
    /// others are skipped. Values without `kit=` parse with a nil `kitVersion`. Every `headerValue` parses.
    public static func parse(_ value: String?) -> StackNestViewerIdentification? {
        guard let text = sanitizeForStorage(value) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let product = parts[0].trimmingCharacters(in: .whitespaces)
        let slash = product.firstIndex(of: "/")
        let bundle = slash.map { String(product[..<$0]) } ?? product
        guard !bundle.isEmpty, bundle.unicodeScalars.count <= maxComponentLength,
              bundle.unicodeScalars.allSatisfy(isComponentScalar) else { return nil }
        var version = slash.map { String(product[product.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
        if version?.isEmpty == true { version = nil }
        version = version.map { String($0.prefix(maxComponentLength)) }
        var format: Int?
        var kit: String?
        for parameter in parts.dropFirst() {
            let pair = parameter.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "format": format = Int(rawValue)
            case "kit":
                let cut = String(rawValue.prefix(maxKitVersionLength))
                kit = !cut.isEmpty && cut.unicodeScalars.allSatisfy(isComponentScalar) ? cut : nil
            default: continue
            }
        }
        return StackNestViewerIdentification(bundleIdentifier: bundle, version: version, format: format,
                                             kitVersion: kit)
    }

    /// 1 つの部分を整える（空になれば nil）。
    static func sanitizedComponent(_ value: String, limit: Int) -> String? {
        let cleaned = String(value.unicodeScalars.map { isComponentScalar($0) ? Character($0) : "_" }.prefix(limit))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// `componentCharacters` が表す文字の集合（その文字列から作る＝定義は 1 つ）。
    private static let componentScalarValues: Set<UInt32> = {
        let body = Array(componentCharacters.unicodeScalars.dropFirst().dropLast())
        var values = Set<UInt32>()
        var index = 0
        while index < body.count {
            if index + 2 < body.count, body[index + 1] == "-" {
                values.formUnion(body[index].value...body[index + 2].value)
                index += 3
            } else {
                values.insert(body[index].value)
                index += 1
            }
        }
        return values
    }()

    static func isComponentScalar(_ scalar: Unicode.Scalar) -> Bool {
        componentScalarValues.contains(scalar.value)
    }
}
