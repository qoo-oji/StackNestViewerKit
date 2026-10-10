import Foundation

/// `Info.plist` の対応の宣言（`StackNestViewerSupport`）の解釈。StackNest が他のアプリの宣言を読むときも、
/// ビューアが自分の宣言を点検するときも、これを使う。
///
///     <key>StackNestViewerSupport</key>
///     <dict>
///       <key>referenceFormatVersions</key>
///       <array><integer>1</integer></array>
///     </dict>
///
/// Interprets the `StackNestViewerSupport` declaration in `Info.plist`, both when StackNest reads another
/// app's declaration and when a viewer checks its own.
public enum StackNestViewerSupport {
    /// `Info.plist` のキー。 / The `Info.plist` key.
    public static let infoPlistKey = "StackNestViewerSupport"
    /// 読める版の配列のキー。 / The key of the array of readable versions.
    public static let versionsKey = "referenceFormatVersions"

    /// 宣言された版。正の `<integer>` だけを宣言の順に返す（真偽値・実数・文字列・0 以下は捨てる。形が違えば空）。
    ///
    /// The declared versions: positive `<integer>` elements in order (booleans, reals, strings and values of
    /// 0 or less are dropped; empty when the shape is wrong).
    public static func declaredVersions(in infoDictionary: [String: Any]) -> [Int] {
        guard let support = infoDictionary[infoPlistKey] as? [String: Any],
              let declared = support[versionsKey] as? [Any]
        else { return [] }
        return declared.compactMap(positiveInteger)
    }

    /// 宣言と書ける版の共通の最大。無ければ nil（＝未対応）。
    ///
    /// The highest version both sides support, or nil (unsupported).
    public static func chooseVersion(declared: some Sequence<Int>, writable: some Sequence<Int>) -> Int? {
        Set(declared).intersection(writable).max()
    }

    /// ビューアの試験から呼ぶ自己点検（実行時には呼ばない）。空なら問題なし。
    ///
    /// A self-check for a viewer's tests (not for run time). Empty means no problems.
    public static func verify(infoDictionary: [String: Any],
                              readableVersions: Set<Int> = StackNestFormat.supportedVersions) -> [Issue]
    {
        guard let value = infoDictionary[infoPlistKey] else { return [.missingKey] }
        guard let support = value as? [String: Any], support[versionsKey] is [Any] else {
            return [.malformedDeclaration]
        }
        let versions = declaredVersions(in: infoDictionary)
        guard !versions.isEmpty else { return [.noVersionDeclared] }
        return versions.filter { !readableVersions.contains($0) }.map(Issue.declaresUnreadableVersion)
    }

    /// 自己点検で見つかる問題。 / A problem found by the self-check.
    public enum Issue: Sendable, Hashable {
        /// キーが無い。 / The key is missing.
        case missingKey
        /// `dict` でない・`referenceFormatVersions` が配列でない。 / Not a dict, or the versions aren't an array.
        case malformedDeclaration
        /// 正の整数の版が 1 つも無い。 / No positive integer version is declared.
        case noVersionDeclared
        /// 宣言した版を部品が読めない（StackNest がその版で書くと開けない）。
        ///
        /// A declared version the kit can't read (files StackNest writes in it wouldn't open).
        case declaresUnreadableVersion(Int)
    }

    /// plist の `<integer>` で正の値だけ。`<true/>` と `<real>1</real>` は `NSNumber` として 1 に橋渡しされて
    /// しまうので、真偽値と浮動小数点を先に外す。
    static func positiveInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if CFNumberIsFloatType(number as CFNumber) { return nil }
        let integer = number.intValue
        return integer > 0 ? integer : nil
    }
}
