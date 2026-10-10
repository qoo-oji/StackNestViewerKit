import Foundation

/// 既定の文言の表（英日）。String Catalog ではなくコードの表にしてある: ホストがアプリの中の言語設定を持つとき
/// 言語を引数で渡せる・リソースのバンドルを持たない（同梱・署名の手順に響かない）・件数が少ない、のため。
/// `%@` はアプリの名前、`%lld` は状態コード。
enum StackNestMessages {
    struct Entry {
        let english: String
        let japanese: String
    }

    /// 表にあるコード（試験が全件の英日・書式の数を確かめる）。
    static let knownCodes: [StackNestViewerError.Code] = [
        .invalidReference, .unsupportedVersion, .expired, .unauthorized, .libraryLocked, .bookNotFound,
        .pageOutOfRange, .hostNotAllowed, .cannotConnect, .insecureConnectionBlocked, .remoteUnavailable,
        .responseTooLarge, .invalidResponse, .httpStatus,
    ]

    private static let unexpected = Entry(
        english: "StackNest returned an unexpected response. Open the book from StackNest again.",
        japanese: "StackNest から想定外の応答が返りました。StackNest から開き直してください。")
    private static let expiredLink = Entry(
        english: "The link to this book has expired. Open the book from StackNest again.",
        japanese: "この本を開くための期限が切れました。StackNest から開き直してください。")

    static let table: [StackNestViewerError.Code: Entry] = [
        .invalidReference: Entry(
            english: "This file isn't a StackNest book reference, or it's damaged.",
            japanese: "このファイルは StackNest の本の参照ファイルではないか、壊れています。"),
        .unsupportedVersion: Entry(
            english: "This StackNest book reference uses a newer format. Update %@ to open it.",
            japanese: "この StackNest の参照ファイルは新しい形式です。開くには %@ を更新してください。"),
        .expired: expiredLink,
        .unauthorized: expiredLink,
        .libraryLocked: Entry(
            english: "Unlock the library in StackNest, then open the book from StackNest again.",
            japanese: "StackNest でライブラリを解錠し、StackNest から開き直してください。"),
        .bookNotFound: Entry(
            english: "This book is no longer in StackNest. Open it from StackNest again.",
            japanese: "この本は StackNest にありません。StackNest から開き直してください。"),
        .pageOutOfRange: Entry(
            english: "This page isn't in the book.",
            japanese: "このページは本にありません。"),
        .hostNotAllowed: Entry(
            english: "This book's address isn't on this Mac, so %@ won't connect to it. Open the book from StackNest again.",
            japanese: "この本の接続先がこの Mac ではないため、%@ は接続しません。StackNest から開き直してください。"),
        .cannotConnect: Entry(
            english: "StackNest isn't running, or its reading-position sync setting is off. Open the book from StackNest again.",
            japanese: "StackNest が起動していないか、読書位置の同期の設定がオフです。StackNest から開き直してください。"),
        .insecureConnectionBlocked: Entry(
            english: "This book's address isn't on this Mac or your local network, so %@ can't reach it. Open the book from StackNest again.",
            japanese: "この本の接続先は、この Mac やローカルネットワークの中にないため、%@ から接続できません。StackNest から開き直してください。"),
        .remoteUnavailable: Entry(
            english: "StackNest couldn't reach the remote library. Try again later.",
            japanese: "StackNest がリモートのライブラリに接続できませんでした。しばらくしてからもう一度お試しください。"),
        .responseTooLarge: unexpected,
        .invalidResponse: unexpected,
        .httpStatus: Entry(
            english: "StackNest returned an error (HTTP %lld).",
            japanese: "StackNest がエラーを返しました（HTTP %lld）。"),
    ]

    /// コードの文言。表に無いコード（ホストが作った独自のコード）は「想定外の応答」。
    static func template(for code: StackNestViewerError.Code, language: StackNestLanguage) -> String {
        let entry = table[code] ?? unexpected
        switch language {
        case .english: return entry.english
        case .japanese: return entry.japanese
        }
    }

    /// 文言に入れるアプリの名前（`CFBundleDisplayName` → `CFBundleName` → プロセス名）。
    static func defaultAppName(bundle: Bundle = .main) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle.object(forInfoDictionaryKey: key) as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return ProcessInfo.processInfo.processName
    }
}
