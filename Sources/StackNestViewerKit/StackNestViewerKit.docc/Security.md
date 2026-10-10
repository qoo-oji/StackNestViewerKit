# セキュリティ / Security

鍵の扱いと、つなぐ宛先の制限。

How the kit handles the token and where it connects.

## 鍵 / The Token

参照ファイルの `token` はその本だけに使える 30 日の秘密。部品はメモリの中だけで使い、``StackNestBookReference`` は
`Codable` ではなく、`description`・`dump` では `<redacted>` になる。ホストも鍵を保存しない（履歴・コレクション・
書き出し・ログに入れない）。本の同一性には参照ファイルのパスを使う（`book` の URL は開くたびに変わることがある）。

The token is a 30-day secret for one book. The kit keeps it in memory only; ``StackNestBookReference`` isn't
`Codable` and redacts the token in descriptions and dumps. Hosts shouldn't store it either. Use the reference file's
path to identify the book (the `book` URL can change each time the book is opened).

## つなぐ宛先 / Hosts

``StackNestBookSession/Configuration-swift.struct/allowedHosts`` の既定は ``StackNestHostPolicy/loopbackOnly``
（`127.0.0.1` と `::1` の字面だけ）。外れた `book` には要求を出さずに `hostNotAllowed` を返す。広げるときは明示する。

The default ``StackNestBookSession/Configuration-swift.struct/allowedHosts`` is ``StackNestHostPolicy/loopbackOnly``
(only the literal addresses `127.0.0.1` and `::1`). Other hosts fail with `hostNotAllowed` without a request.

```swift
import StackNestViewerKit

func lanConfiguration() -> StackNestBookSession.Configuration {
    var configuration = StackNestBookSession.Configuration()
    configuration.allowedHosts = .loopback(plus: ["192.0.2.10"])
    return configuration
}
```

## 要求 / Requests

- リダイレクトには付いて行かない（3xx は `httpStatus`）。鍵は `book` の宛先にだけ送る。
- 本文は既定で 64 MiB まで（`responseTooLarge`）。期限は要求のたびに確かめる（`expired`）。
- `waitLimit`（既定 25 秒）は要求ごとに数え、少しずつ流れ続ける応答でも超えれば `cannotConnect` で戻る。1 回の呼び出し
  （async も同期も）は要求を最大 3 件（範囲の確かめ・ページ・404 の後の読み直し）出しうるので、最悪で `waitLimit` の
  3 倍まで待ってから戻る。
- `URLSession` はキャッシュ・クッキー・資格情報の保管を持たない。

- Redirects are refused (3xx fails with `httpStatus`); the token goes only to the `book` origin.
- Bodies are capped at 64 MiB by default (`responseTooLarge`); expiry is checked before every request (`expired`).
- `waitLimit` (25 seconds by default) is counted per request, and a request that exceeds it fails with
  `cannotConnect`, even if the response is trickling in. A single call (async or blocking) can make up to three
  requests (range check, the page, a manifest re-read after a 404), so in the worst case it waits up to three times
  `waitLimit` before returning.
- The `URLSession` has no cache, cookie or credential storage.
