import Foundation

/// 書庫のエントリの形でページを扱うホスト向けの仮の名前（`000041.jpg`）。StackNest のページ番号（0 始まり）を
/// 6 桁のゼロ埋めで持つ。拡張子は画像の道具を通すためのもので、中身の形式は `StackNestPage.contentType` で分かる。
///
/// Synthetic entry names (`000041.jpg`) for hosts that treat pages as archive entries. The extension only
/// lets image tooling accept the name; the real format is in `StackNestPage.contentType`.
public enum StackNestPageNaming {
    /// ページ番号の名前。 / The name of a page number.
    public static func entryName(forPage index: Int) -> String {
        String(format: "%06ld.jpg", index)
    }

    /// `entryName(forPage:)` が作る形のときだけ番号を返す（桁の足りない名前・別の拡張子は nil）。
    ///
    /// The page number, only for names `entryName(forPage:)` produces.
    public static func pageIndex(fromEntryName name: String) -> Int? {
        guard name.hasSuffix(".jpg") else { return nil }
        let digits = name.dropLast(4)
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let index = Int(digits),
              entryName(forPage: index) == name
        else { return nil }
        return index
    }

    /// ページ数ぶんの名前（StackNest の番号順）。 / The names of all pages, in StackNest order.
    public static func entryNames(pageCount: Int) -> [String] {
        (0..<max(pageCount, 0)).map(entryName(forPage:))
    }
}
