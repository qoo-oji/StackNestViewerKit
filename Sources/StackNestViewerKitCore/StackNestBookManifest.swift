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
    /// ページの名前（StackNest のページ番号の順。`pageNames[n]` が `pages/{n}` の名前）。書庫の本は書庫の中のパス
    /// （`フォルダ/001.jpg`。区切りは `/`）、フォルダの本はファイル名。頼んだとき（`Configuration.requestsPageNames`）
    /// だけ StackNest が付ける。PDF・画像の EPUB・古い StackNest では付かず nil。名前は本の中から来た信頼できない
    /// 文字列で、表示と見分けのためのもの: ファイルのパスとして使わない（`..` や先頭の `/` を含むことがある）。
    ///
    /// The page names in StackNest page order (`pageNames[n]` names `pages/{n}`): the path inside the archive for
    /// archive books (`folder/001.jpg`, separated by `/`), the file name for folder books. StackNest sends them only
    /// when asked (`Configuration.requestsPageNames`); PDFs, image EPUBs and older StackNest versions give nil. The
    /// names come from inside the book and aren't trusted: use them for display and to tell pages apart, never as
    /// file system paths (they can contain `..` or start with `/`).
    public let pageNames: [String]?

    /// 値から作る。 / Creates a manifest from values.
    public init(pageCount: Int, direction: StackNestReadingDirection?, format: String?, etag: String?,
                pageNames: [String]? = nil)
    {
        self.pageCount = pageCount
        self.direction = direction
        self.format = format
        self.etag = etag
        self.pageNames = pageNames
    }

    /// manifest の JSON を読む。読めない・ページ数が整数でない・上限を超えるなら `.invalidResponse`。
    /// `pageNames` は `acceptablePageNames(_:pageCount:)` に通らなければ、manifest を断らずに nil にする。
    ///
    /// Parses manifest JSON. Throws `.invalidResponse` when it can't be read or the page count is invalid.
    /// `pageNames` that fail `acceptablePageNames(_:pageCount:)` become nil instead of failing the manifest.
    public static func parse(_ data: Data) throws -> StackNestBookManifest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pageCount = JSONValues.integer(root["pageCount"]),
              (0...StackNestFormat.maxPageCount).contains(pageCount)
        else { throw StackNestViewerError(.invalidResponse) }
        return StackNestBookManifest(
            pageCount: pageCount,
            direction: (root["direction"] as? String).map(StackNestReadingDirection.init(rawValue:)),
            format: root["format"] as? String, etag: root["etag"] as? String,
            pageNames: acceptablePageNames(root["pageNames"], pageCount: pageCount))
    }

    /// 1 つのページの名前の長さの上限（UTF-8 のバイト数）。 / The longest accepted page name, in UTF-8 bytes.
    public static let maxPageNameBytes = 1024

    /// ページの名前の一覧の検査。文字列の配列で、数がページ数と同じ、どの名前も空でなく `maxPageNameBytes` 以下で
    /// 制御文字（改行・NUL など）を含まず、重複しないときだけ返す。1 つでも外れたら一覧ごと捨てる（番号と名前の
    /// 対応が崩れた一覧を部分的に使わない）。
    ///
    /// Checks a page name list: an array of strings with one name per page, each non-empty, at most
    /// `maxPageNameBytes`, free of control characters (newlines, NUL and so on) and unique. One bad entry drops the
    /// whole list, so a list whose numbering may be off is never used in part.
    static func acceptablePageNames(_ value: Any?, pageCount: Int) -> [String]? {
        guard let names = value as? [Any], names.count == pageCount else { return nil }
        var result: [String] = []
        result.reserveCapacity(names.count)
        var seen = Set<String>()
        for case let name as String in names {
            guard !name.isEmpty, name.utf8.count <= maxPageNameBytes,
                  !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  seen.insert(name).inserted
            else { return nil }
            result.append(name)
        }
        return result.count == pageCount ? result : nil
    }
}
