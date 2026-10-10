import Foundation

/// 部品より前のビューア（参照ファイルを自前で読んでいた実装）の読み手を、そのまま凍結した写し。部品が書く
/// 参照ファイルを、部品を使わない古いビューアでも開けることを押さえる（作る側の互換）。**直さない**: この写しを
/// 部品に合わせて変えると、互換の試験が意味を失う。
enum LegacyReferenceReader {
    struct Reference: Equatable {
        let version: Int
        let title: String
        let bookURL: URL
        let token: String
        let expiresAt: Date
        let pageCount: Int
        let direction: String?
        let startPage: Int
    }

    enum Failure: Error, Equatable {
        case unreadableFile
        case unsupportedVersion(Int?)
    }

    static let format = "stacknest-book-reference"
    static let readableVersions: Set<Int> = [1]
    static let maxPageCount = 100_000

    static func parse(_ data: Data) throws -> Reference {
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw Failure.unreadableFile
        }
        guard root["format"] as? String == format else { throw Failure.unreadableFile }
        guard let version = integer(root["version"]) else { throw Failure.unsupportedVersion(nil) }
        guard version >= 1 else { throw Failure.unreadableFile }
        guard readableVersions.contains(version) else { throw Failure.unsupportedVersion(version) }
        guard let bookString = root["book"] as? String,
              !bookString.contains("?"), !bookString.contains("#"),
              let bookURL = URL(string: bookString),
              let scheme = bookURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = bookURL.host(percentEncoded: false),
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hasUserInfo(bookURL),
              let token = root["token"] as? String, !token.isEmpty,
              let expiresString = root["expiresAt"] as? String, let expiresAt = date(expiresString),
              let pageCount = integer(root["pageCount"]), (0...maxPageCount).contains(pageCount),
              let startPage = integer(root["startPage"]), startPage >= 0
        else { throw Failure.unreadableFile }
        return Reference(
            version: version, title: root["title"] as? String ?? "", bookURL: bookURL, token: token,
            expiresAt: expiresAt, pageCount: pageCount, direction: root["direction"] as? String, startPage: startPage)
    }

    private static func hasUserInfo(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        return components.user != nil || components.password != nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return number.intValue
    }

    private static func date(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }
}
