import Foundation

/// 参照ファイル（`.stacknestbook`）の形式の定数。
///
/// Constants of the reference file (`.stacknestbook`) format.
public enum StackNestFormat {
    /// `format` の値。 / The value of the `format` key.
    public static let formatName = "stacknest-book-reference"
    /// 拡張子。 / The file name extension.
    public static let fileExtension = "stacknestbook"
    /// UTType（`public.json` に準拠）。 / The uniform type identifier (conforms to `public.json`).
    public static let typeIdentifier = "app.shelfsmith.stacknest.book-reference"
    /// この版の部品が読み書きできる参照ファイルの版。
    ///
    /// Reference file versions this release of the kit reads and writes.
    public static let supportedVersions: Set<Int> = [1]
    /// 参照ファイルの大きさの上限（実物は数百バイト）。
    ///
    /// The size limit of a reference file in bytes (real files are a few hundred bytes).
    public static let maxFileBytes = 1 << 20
    /// ページ数の上限（ページの仮の名前が 6 桁に収まる範囲）。
    ///
    /// The page count limit (keeps synthetic page names at six digits).
    public static let maxPageCount = 100_000
}
