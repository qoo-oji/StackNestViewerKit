# エラーと文言 / Errors and Localization

``StackNestViewerError`` の受け方と、既定の英日の文言。

Handling ``StackNestViewerError`` and the default English and Japanese messages.

## コードで分ける / Switching on the Code

エラーは列挙ではなくコードを持つ構造体なので、コードが増えてもホストのコンパイルは壊れない。`default` を必ず書く。
`isPermanent` は StackNest から開き直すまで直らない失敗。セッションは恒久的な失敗を一度受けたら、以後のページ・
manifest・表紙を要求なしで同じ失敗で返す（先読みの指示も無視する。書き戻しだけは要求を出す）。

The error is a struct with a code, so new codes don't break the host's build. Always include `default`.
`isPermanent` marks failures that last until the book is opened from StackNest again. Once a session has received
a permanent failure, later page, manifest and cover calls fail with that same error without a request (prefetch
instructions are ignored too; only progress write-backs still make their request).

```swift
import StackNestViewerKit

func notice(for error: StackNestViewerError, appName: String) -> String? {
    switch error.code {
    case .pageOutOfRange:
        return nil  // ホストの「ページが無い」の表示に任せる
    default:
        return error.message(language: .preferred, appName: appName)
    }
}
```

## 言語 / Language

`message(language:appName:)` の既定の言語は `Bundle.main.preferredLocalizations` の先頭（日本語なら日本語、ほかは
英語）。アプリの中に独自の言語設定を持つホストは `StackNestLanguage(locale:)` で渡す。文言を差し替えたいコードは、
ホストが自分の String Catalog で受ける。文言には鍵も `book` の資格情報も入らない。

The default language follows `Bundle.main.preferredLocalizations` (Japanese for Japanese, English otherwise). Hosts
with an in-app language setting pass `StackNestLanguage(locale:)`. To replace a message, handle that code with the
host's own strings. Messages never contain the token or credentials.

```swift
import Foundation
import StackNestViewerKit

func localizedNotice(_ error: StackNestViewerError, appLocale: Locale) -> String {
    error.message(language: StackNestLanguage(locale: appLocale), appName: "Example Viewer")
}
```
