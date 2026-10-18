# セキュリティ / Security

鍵の扱いと、つなぐ宛先の制限。

How the kit handles the token and where it connects.

## 鍵 / The Token

参照ファイルの `token` はその本だけに使える、最長 30 日の秘密（中継されたリモートの本では、30 日とリモートの鍵の期限の早い方）。部品はメモリの中だけで使い、``StackNestBookReference`` は
`Codable` ではなく、`description`・`dump` では `<redacted>` になる。ホストも鍵を保存しない（履歴・コレクション・
書き出し・ログに入れない）。本の同一性には参照ファイルのパスを使う（`book` の URL は開くたびに変わることがある）。

The token is a secret for one book, valid for at most 30 days (for relayed remote books, until the earlier of 30 days and the remote key's expiry). The kit keeps it in memory only; ``StackNestBookReference`` isn't
`Codable` and redacts the token in descriptions and dumps. Hosts shouldn't store it either (not in history, collections, exports or logs). Use the reference file's
path to identify the book (the `book` URL can change each time the book is opened).

## つなぐ宛先 / Hosts

``StackNestBookSession/Configuration-swift.struct/allowedHosts`` の既定は ``StackNestHostPolicy/loopbackOnly``
（`127.0.0.1` と `::1` の字面だけ）。外れた `book` には要求を出さずに `hostNotAllowed` を返す。広げるときは明示する。

The default ``StackNestBookSession/Configuration-swift.struct/allowedHosts`` is ``StackNestHostPolicy/loopbackOnly``
(only the literal addresses `127.0.0.1` and `::1`). Other hosts fail with `hostNotAllowed` without a request; widening the list must be explicit.

```swift
import StackNestViewerKit

func lanConfiguration() -> StackNestBookSession.Configuration {
    var configuration = StackNestBookSession.Configuration()
    configuration.allowedHosts = .loopback(plus: ["192.0.2.10"])
    return configuration
}
```

## パスの形 / Book Paths

宛先を loopback に絞っても、ポートとパスは参照ファイルが決める。書き換えた参照ファイルの `book` が 127.0.0.1 の別の
サービスの道を指すと、鍵の付いた決まった形の要求（`GET …/manifest`・`POST …/progress` など）をそのサービスへ送って
しまう。そのため既定では、`book` のパスが StackNest の書く形（`/api/v1/libraries/<library>/books/<id>` と
`/api/v1/relay/<relayID>`。区切りは英数字と `-._~` だけ・末尾のスラッシュは 1 つまで）のときだけ要求を出し、ほかは
要求なしで `invalidReference` を返す（``StackNestBookSession/init(contentsOf:configuration:)`` は開く時点で断る）。
ほかの形の基点へ承知でつなぐときだけ ``StackNestBookSession/Configuration-swift.struct/allowsAnyBookPath`` を立てる。

Restricting hosts to loopback still leaves the port and path to the reference file. If a tampered file points `book`
at a path of another service on 127.0.0.1, the session would send that service fixed-shape requests carrying the
token (`GET …/manifest`, `POST …/progress` and so on). So by default the session makes requests only when the path
of `book` has one of the shapes StackNest writes (`/api/v1/libraries/<library>/books/<id>` and
`/api/v1/relay/<relayID>`, with segments of letters, digits and `-._~` only and at most one trailing slash), and
otherwise fails with `invalidReference` without a request
(``StackNestBookSession/init(contentsOf:configuration:)`` refuses when opening). Set
``StackNestBookSession/Configuration-swift.struct/allowsAnyBookPath`` only when you knowingly connect to a base of
another shape.

## 要求 / Requests

- リダイレクトには付いて行かない（3xx は `httpStatus`）。鍵は `book` の宛先にだけ送る。
- 本文は既定で 64 MiB まで（`responseTooLarge`）。2xx でない応答は状態コードで振り分け、本文は受け取らない（大きな本文を
  付けた 401 でも `unauthorized`）。期限は要求のたびに確かめる（`expired`）。
- `waitLimit`（既定 25 秒）は要求ごとに数え、少しずつ流れ続ける応答でも超えれば `cannotConnect` で戻る。1 回の呼び出し
  （async も同期も）は要求を最大 3 件（範囲の確かめ・ページ・404 の後の読み直し）出しうるので、最悪で `waitLimit` の
  3 倍まで待ってから戻る。
- `URLSession` はキャッシュ・クッキー・資格情報の保管を持たない。プロキシは使わない（システムや PAC のプロキシは無効にする）ので、鍵がプロキシへ渡ることはない。

- Redirects are refused (3xx fails with `httpStatus`); the token goes only to the `book` origin. The kit never uses a proxy (system and PAC proxies are disabled), so the token can't reach one.
- Bodies are capped at 64 MiB by default (`responseTooLarge`). Non-2xx responses are classified by their status
  code and their bodies are never read (a 401 with a large body is still `unauthorized`). Expiry is checked before
  every request (`expired`).
- `waitLimit` (25 seconds by default) is counted per request, and a request that exceeds it fails with
  `cannotConnect`, even if the response is trickling in. A single call (async or blocking) can make up to three
  requests (range check, the page, a manifest re-read after a 404), so in the worst case it waits up to three times
  `waitLimit` before returning.
- The `URLSession` has no cache, cookie or credential storage.
