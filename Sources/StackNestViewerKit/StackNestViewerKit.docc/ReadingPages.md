# ページを読む / Reading Pages

ページ・先読み・縮小・キャッシュ・解読の枠の扱い。

Pages, prefetching, smaller images, the cache and decoding slots.

## ページ / Pages

``StackNestBookSession/page(_:maxWidth:priority:)`` はバイト列と `Content-Type` を返す。中身は JPEG・PNG・WebP の
ことがあり、中継されたリモートの本では、`maxWidth` を付けない（または 1600 の）とき、幅が 1600 ピクセルを超える
ページは長い辺が 1600 ピクセル以内に縮んで JPEG で届く。形式は `contentType` か中身で見る。同じページの同時の要求は
1 件にまとまり、直近のページ（既定 8 枚・合計 64 MiB。1 枚が合計の半分を超えるページは持たない）はメモリに持つ。
持たないページは読むたびに取り直す。既定では、32 MiB を超え `maxResponseBytes`（既定 64 MiB）までのページがそうなる。
そういうページのある本を読むなら `pageCacheBytes` を上げる。

``StackNestBookSession/page(_:maxWidth:priority:)`` returns the bytes and the `Content-Type`. Pages may be JPEG,
PNG or WebP; check the format by `contentType` or the bytes. For relayed remote books, when `maxWidth` is omitted (or 1600), pages wider than 1600 pixels arrive
scaled so the longer side is at most 1600 pixels, as JPEG. Concurrent requests for the same page share one request,
and recent pages (8 pages and 64 MiB in total by default; a page larger than half of that isn't kept) stay in memory.
A page that isn't kept is fetched again on every read; with the defaults that means pages over 32 MiB and up to
`maxResponseBytes` (64 MiB by default). Raise `pageCacheBytes` for books with such pages.

本のページ数は開いた後に変わることがある。``StackNestBookSession/manifest(refresh:)`` に `refresh: true` を渡すと、
呼んだ後に出した要求の答えを返す（その前から飛んでいる manifest の要求には乗らない）。`pages/{n}` の 404 の後の
確かめも同じで、減ったページ数で `pageOutOfRange` に振り分ける。`refresh` を付けない読み出しは、飛んでいる要求に乗る。

A book's page count can change after it is opened. With `refresh: true`,
``StackNestBookSession/manifest(refresh:)`` answers from a request made after the call (it never joins a manifest
request already in flight). The check after a `pages/{n}` 404 works the same way, so a shrunk book is reported as
`pageOutOfRange`. Reads without `refresh` join a request in flight.

```swift
import StackNestViewerKit

func thumbnail(_ session: StackNestBookSession, page: Int) async throws -> StackNestPage {
    // ?maxw= で小さく取る（幅もキャッシュの鍵に入る）。
    try await session.page(page, maxWidth: 320, priority: .prefetch)
}
```

## メモリの量 / Memory Use

リソースの監視を持つホストは、``StackNestBookSession/cachedPageBytes``（キャッシュに持っているページ）と
``StackNestBookSession/bufferedResponseBytes``（受け取り中の本文）で、セッションのメモリを数えられる。どちらも
ロックの中で数を読むだけで、呼ぶ側を待たせない。返したページはキャッシュと同じバッファを指していることがあるので、
ホストが自分で持つページの大きさと足すと二重に数えることがある。

Hosts with a resource monitor can account for a session's memory with ``StackNestBookSession/cachedPageBytes``
(pages kept in the cache) and ``StackNestBookSession/bufferedResponseBytes`` (bodies still arriving). Both only read
a count under a lock and never make the caller wait. A returned page may share its buffer with the cache, so adding
the size of pages the host keeps itself can count the same bytes twice.

```swift
import StackNestViewerKit

func memoryInUse(by session: StackNestBookSession) -> Int {
    session.cachedPageBytes + session.bufferedResponseBytes
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

## 解読の枠 / Decoding Slots

部品はホストの画像の解読の枠を知らない。ホストは**バイト列を取り終えてから**枠を取る（網の待ちで枠を握らない）。
先読みの取り中のページに表示の要求が乗ったら、枠の列でも表示の側へ並べ直す（部品が上げるのは網の優先度だけ）。

The kit doesn't know about the host's decoding slots. Take a slot **after** the bytes arrive, and when a display
request joins a page being prefetched, move it to the display queue for slots too (the kit only raises the network priority).
