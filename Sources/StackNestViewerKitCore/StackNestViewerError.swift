import Foundation

/// 部品が返す失敗。列挙ではなく「コードを持つ構造体」にしてある（`URLError` と同じ形）。コードが増えても、
/// `switch error.code { … default: … }` で受けるホストのコンパイルは壊れない。
///
/// A failure reported by the kit. It is a struct carrying a code rather than an enum (like `URLError`), so
/// adding codes later doesn't break hosts that `switch error.code { … default: … }`.
public struct StackNestViewerError: Error, Sendable, Hashable, LocalizedError {
    /// 失敗の種類。 / The kind of failure.
    public struct Code: RawRepresentable, Sendable, Hashable {
        /// コードを表す文字列。 / The string that names the code.
        public let rawValue: String

        /// 文字列からコードを作る（ホストが独自のコードを作れる。表に無いコードの文言は「想定外の応答」）。
        ///
        /// Creates a code from a string (hosts can make their own; a code missing from the table gets the
        /// "unexpected response" message).
        public init(rawValue: String) { self.rawValue = rawValue }

        /// 参照ファイルではない・壊れている・必須の項目が無い。 / Not a reference file, damaged, or missing a required key.
        public static let invalidReference = Code(rawValue: "invalidReference")
        /// 読めない版（`formatVersion` に版。整数でない・無いときは nil）。 / A version this kit can't read.
        public static let unsupportedVersion = Code(rawValue: "unsupportedVersion")
        /// 期限を過ぎた（要求は出していない）。 / The token expired (no request was made).
        public static let expired = Code(rawValue: "expired")
        /// 401、または `X-Library-Locked` の無い 403。 / 401, or 403 without `X-Library-Locked`.
        public static let unauthorized = Code(rawValue: "unauthorized")
        /// 403 に `X-Library-Locked: 1`。 / 403 with `X-Library-Locked: 1`.
        public static let libraryLocked = Code(rawValue: "libraryLocked")
        /// 本が無い（404）。 / The book is gone (404).
        public static let bookNotFound = Code(rawValue: "bookNotFound")
        /// 範囲外のページ（`pageCount` に既知のページ数）。 / A page outside the book (`pageCount` holds the known count).
        public static let pageOutOfRange = Code(rawValue: "pageOutOfRange")
        /// つないでよいホストではない（要求は出していない）。 / The host isn't allowed (no request was made).
        public static let hostNotAllowed = Code(rawValue: "hostNotAllowed")
        /// つながらない・時間切れ。 / Couldn't connect, or timed out.
        public static let cannotConnect = Code(rawValue: "cannotConnect")
        /// App Transport Security が平文の HTTP を止めた。 / App Transport Security blocked plain HTTP.
        public static let insecureConnectionBlocked = Code(rawValue: "insecureConnectionBlocked")
        /// 中継の先のリモートに届かない（502）。 / The relay couldn't reach the remote library (502).
        public static let remoteUnavailable = Code(rawValue: "remoteUnavailable")
        /// 応答が上限を超えた。 / The response exceeded the size limit.
        public static let responseTooLarge = Code(rawValue: "responseTooLarge")
        /// 応答が形式どおりでない。 / The response isn't in the expected form.
        public static let invalidResponse = Code(rawValue: "invalidResponse")
        /// そのほかの状態コード（`statusCode` に値。3xx を含む）。 / Any other status code (in `statusCode`; includes 3xx).
        public static let httpStatus = Code(rawValue: "httpStatus")
    }

    /// 知らせを重ねないための種類。`.expired` は `.unauthorized` と同じ種類（文言が同じ）。`.httpStatus` は
    /// 状態コードごとに別の種類（500 の知らせの後に 503 も知らせる）。
    ///
    /// The kind used to avoid repeating a notice. `.expired` shares `.unauthorized`'s kind (same message);
    /// `.httpStatus` has one kind per status code (a 503 is shown after a 500).
    public struct NoticeKind: Sendable, Hashable {
        /// 失敗の種類。 / The kind of failure.
        public let code: Code
        /// `.httpStatus` のときだけ入る。 / Set only for `.httpStatus`.
        public let statusCode: Int?
    }

    /// 失敗の種類。 / The kind of failure.
    public let code: Code
    /// `.httpStatus` の状態コード。 / The status code of `.httpStatus`.
    public let statusCode: Int?
    /// `.unsupportedVersion` の版（整数でない・無いときは nil）。 / The version for `.unsupportedVersion`.
    public let formatVersion: Int?
    /// `.pageOutOfRange` のときの既知のページ数（ホストが一覧を縮められる）。
    ///
    /// The known page count for `.pageOutOfRange`, so the host can shrink its page list.
    public let pageCount: Int?

    /// 失敗を作る。付随する値は、そのコードで意味のあるものだけを渡す。
    ///
    /// Creates a failure. Pass only the values that mean something for the code.
    public init(_ code: Code, statusCode: Int? = nil, formatVersion: Int? = nil, pageCount: Int? = nil) {
        self.code = code
        self.statusCode = statusCode
        self.formatVersion = formatVersion
        self.pageCount = pageCount
    }

    private static let permanentCodes: Set<Code> = [.expired, .unauthorized, .bookNotFound, .libraryLocked, .hostNotAllowed]

    /// StackNest から開き直すまで直らない失敗か（書き戻しの役はこの後は送らない）。
    ///
    /// Whether the failure lasts until the book is opened from StackNest again (progress stops after it).
    public var isPermanent: Bool { Self.permanentCodes.contains(code) }

    /// 知らせの種類。 / The notice kind.
    public var noticeKind: NoticeKind {
        if code == .expired { return NoticeKind(code: .unauthorized, statusCode: nil) }
        if code == .httpStatus { return NoticeKind(code: .httpStatus, statusCode: statusCode) }
        return NoticeKind(code: code, statusCode: nil)
    }

    /// 既定の文言。`appName` を省くと `Bundle.main` の `CFBundleDisplayName` → `CFBundleName` → プロセス名。
    /// 鍵（token）と `book` の資格情報は決して入らない。
    ///
    /// The default message. Without `appName`, uses `CFBundleDisplayName`, then `CFBundleName`, then the
    /// process name. Never contains the token or credentials.
    public func message(language: StackNestLanguage = .preferred, appName: String? = nil) -> String {
        let template = StackNestMessages.template(for: code, language: language)
        let status = statusCode.map(String.init) ?? "?"
        return template
            .replacingOccurrences(of: "%lld", with: status)
            .replacingOccurrences(of: "%@", with: appName ?? StackNestMessages.defaultAppName())
    }

    /// `message()` と同じ（既定の言語・アプリの名前）。
    ///
    /// The same as `message()` (default language and app name).
    public var errorDescription: String? { message() }
}
