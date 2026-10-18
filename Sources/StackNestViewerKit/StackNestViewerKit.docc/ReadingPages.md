# ページを読む / Reading Pages

ページ・先読み・縮小・キャッシュ・解読の枠の扱い。

Pages, prefetching, smaller images, the cache and decoding slots.

## ページ / Pages

``StackNestBookSession/page(_:maxWidth:priority:)`` はバイト列と `Content-Type` を返す。中身は JPEG・PNG・WebP の
ことがあり、中継されたリモートの本では、`maxWidth` を付けない（または 1600 の）とき、幅が 1600 ピクセルを超える
ページは長い辺が 1600 ピクセル以内に縮んで JPEG で届く。形式は `contentType` か中身で見る。同じページの同時の要求は
1 件にまとまり、直近のページ（既定 8 枚・合計 64 MiB。1 枚が合計の半分を超えるページは持たない）はメモリに持つ。

``StackNestBookSession/page(_:maxWidth:priority:)`` returns the bytes and the `Content-Type`. Pages may be JPEG,
PNG or WebP; check the format by `contentType` or the bytes. For relayed remote books, when `maxWidth` is omitted (or 1600), pages wider than 1600 pixels arrive
scaled so the longer side is at most 1600 pixels, as JPEG. Concurrent requests for the same page share one request,
and recent pages (8 pages and 64 MiB in total by default; a page larger than half of that isn't kept) stay in memory.

```swift
import StackNestViewerKit

func thumbnail(_ session: StackNestBookSession, page: Int) async throws -> StackNestPage {
    // ?maxw= で小さく取る（幅もキャッシュの鍵に入る）。
    try await session.page(page, maxWidth: 320, priority: .prefetch)
}
```

## 先読み / Prefetching

``StackNestBookSession/prefetch(_:maxWidth:)`` は指示を置き換える。外れた取得中の先読みは（表示の要求が乗って
いなければ）取り消され、同時に走る先読みは 2 件まで。**読む向きの近いページから**渡す（StackNest の中継は、届いた
要求から読む向きを推し量る）。表示の要求は先読みの数の上限に数えられず、先読みの取り中のページに乗ったら優先度が
上がる。

``StackNestBookSession/prefetch(_:maxWidth:)`` replaces earlier instructions; fetches no longer wanted are
cancelled (unless a display request joined them) and at most two prefetches run at once. Pass pages **nearest in
reading direction first** (StackNest's relay infers the direction from requests). Display requests don't count
toward the prefetch limit, and one that joins a page being prefetched raises its priority.

```swift
import StackNestViewerKit

func pageDidChange(to page: Int, session: StackNestBookSession, pageCount: Int) {
    // 読む向きに近い順（次・その次・ひとつ前）。番号は StackNest のページ番号。
    let nearby = [page + 1, page + 2, page - 1].filter { $0 >= 0 && $0 < pageCount }
    session.prefetch(nearby)
}
```

## 同時の要求 / Concurrent Requests

セッションが同時に出す要求は ``StackNestBookSession/Configuration-swift.struct/maxConcurrentRequests``（既定 6）まで。
多くのスレッドから一度に `page(_:)` を呼んでも、残りはセッションの中の列で待ち、枠が空くと書き戻し → 表示の要求が
乗っている件 → 先読みだけの件の順に出る（同じ組の中は来た順。列で待つ先読みの件に表示の要求が乗れば前へ出る）。
`URLSession` の宛先ごとの接続の数も同じ値にするので、`URLSession` の中で待つことはない（そこでは優先度は目安に
しかならず、表示の要求が先読みの後ろで待たされうる）。列で待つ間も `waitLimit` は進み、待つ人が誰もいなくなった件は
要求を出さずに外れる。遅い中継の本で一度に多くのページを頼むと、後の方は StackNest へ届かないまま `cannotConnect`
で戻ることがある。いま見せるページから頼む。

A session has at most ``StackNestBookSession/Configuration-swift.struct/maxConcurrentRequests`` (6 by default)
requests in flight. When many threads call `page(_:)` at once, the rest wait in the session's own queue and start as
slots free up: progress write-backs first, then fetches a display request is waiting for, then prefetch-only fetches
(first come, first served within each group; a queued prefetch that a display request joins moves ahead).
`URLSession`'s per-host connection limit is set to the same value, so nothing waits inside `URLSession`, where
priority is only a hint and display requests could be stuck behind prefetches. `waitLimit` keeps running while a
request is queued, and a queued fetch whose waiters all leave is dropped without a request. When a slow relayed
book is asked for many pages at once, the later ones can fail with `cannotConnect` without reaching StackNest, so
ask for the pages being shown first.

## 解読の枠 / Decoding Slots

部品はホストの画像の解読の枠を知らない。ホストは**バイト列を取り終えてから**枠を取る（網の待ちで枠を握らない）。
先読みの取り中のページに表示の要求が乗ったら、枠の列でも表示の側へ並べ直す（部品が上げるのは網の優先度だけ）。

The kit doesn't know about the host's decoding slots. Take a slot **after** the bytes arrive, and when a display
request joins a page being prefetched, move it to the display queue for slots too (the kit only raises the network priority).
