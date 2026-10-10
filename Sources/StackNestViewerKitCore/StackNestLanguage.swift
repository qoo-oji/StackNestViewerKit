import Foundation

/// 部品の既定の文言の言語（英語と日本語）。
///
/// The language of the kit's default messages (English and Japanese).
public enum StackNestLanguage: Sendable, Hashable {
    /// 英語。 / English.
    case english
    /// 日本語。 / Japanese.
    case japanese

    /// ロケールの言語から選ぶ（日本語なら日本語、ほかは英語）。アプリの中に独自の言語設定を持つホストが使う。
    ///
    /// Picks the language of a locale (Japanese for Japanese, English otherwise). For hosts with their own
    /// in-app language setting.
    public init(locale: Locale) {
        self = locale.language.languageCode == .japanese ? .japanese : .english
    }

    /// アプリの表示言語（`Bundle.main.preferredLocalizations` の先頭。アプリごとの言語設定に従う）。
    ///
    /// The app's display language (the first of `Bundle.main.preferredLocalizations`, which follows the
    /// per-app language setting).
    public static var preferred: StackNestLanguage {
        let first = Bundle.main.preferredLocalizations.first ?? "en"
        return first.lowercased().hasPrefix("ja") ? .japanese : .english
    }
}
