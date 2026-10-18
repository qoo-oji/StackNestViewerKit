# 変更履歴 / Changelog

注目すべき変更をすべてここに記録する。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版は
[Semantic Versioning](https://semver.org/lang/ja/) に従う。各項目は日本語と英語で書く（GitHub Release の本文になる）。

All notable changes are recorded here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/). Each entry is written in Japanese and English; it becomes the GitHub
Release notes.

## [Unreleased]

### 追加 / Added

- `StackNestBookSession.Configuration.maxConcurrentRequests`（既定 6）。セッションが同時に出す要求の上限。
  `StackNestBookSession.Configuration.maxConcurrentRequests` (6 by default), the most requests a session has in flight at once.

### 変更 / Changed

- セッションは同時に出す要求を `maxConcurrentRequests` までに絞り、残りを自分の列で待たせて、書き戻し → 表示の要求 → 先読みの順に出す（列で待つ先読みに表示の要求が乗れば前へ出る。待つ人がいなくなった件は要求を出さずに外す）。`URLSession` の宛先ごとの接続の数も同じ値にする。これまでは要求をすべてすぐ `URLSession` へ渡していたので、多くのスレッドから一度にページを頼むと、宛先ごとの接続の数（macOS の既定 6）を超えた分が `URLSession` の中で待ち、表示の要求が先読みの後ろで時間切れになったり、遅い中継では StackNest へ届かないまま `cannotConnect` で戻ったりした。
  A session now keeps at most `maxConcurrentRequests` requests in flight; the rest wait in its own queue and start in this order: progress write-backs, display requests, prefetches (a queued prefetch that a display request joins moves ahead, and a queued fetch whose waiters all leave is dropped without a request). `URLSession`'s per-host connection limit is set to the same value. Previously every request went to `URLSession` at once, so when many threads asked for pages together, those beyond the per-host limit (6 by default on macOS) waited inside `URLSession`, where display requests could time out behind prefetches, or, with a slow relay, fail with `cannotConnect` without ever reaching StackNest.

## [0.1.0] - 2026-10-18

### 追加 / Added

- 参照ファイル（`.stacknestbook`・版 1）の型 `StackNestBookReference` と検査・作る側の `encodedJSON()`・manifest の型。
  The `.stacknestbook` reference file (version 1) type `StackNestBookReference` with validation, the producer's `encodedJSON()`, and the manifest type.
- `Info.plist` の対応の宣言 `StackNestViewerSupport` の解釈と自己点検、名乗り `X-StackNest-Viewer`（`kit=` 付き）。
  Interpretation and self-check of the `StackNestViewerSupport` declaration in `Info.plist`, and the `X-StackNest-Viewer` header with `kit=`.
- エラーの型 `StackNestViewerError` と、英日の既定の文言。
  The `StackNestViewerError` type with default English and Japanese messages.
- 本のセッション `StackNestBookSession`: manifest・ページ・表紙・書き戻し・先読み・メモリのキャッシュ。既定では `127.0.0.1` と `::1` にしかつながない。
  `StackNestBookSession` for the manifest, pages, cover, progress, prefetching and an in-memory cache; connects only to `127.0.0.1` and `::1` by default.
- 同期の読み出し API を持つビューアのための `StackNestBlockingReader`。
  `StackNestBlockingReader` for viewers with a synchronous reading API.
- 読書位置の書き戻し `StackNestProgressReporter` と、終了時の送り切り `StackNestProgressRegistry`。
  `StackNestProgressReporter` for writing the reading position back, and `StackNestProgressRegistry` for flushing at quit.
- 試験の道具 `StackNestViewerKitTesting`（`URLProtocol` の見立てとサンプル）。
  `StackNestViewerKitTesting` with a `URLProtocol` stub server and samples.
- 形式の文書（日英）とサンプルの参照ファイル、DocC の手引き。
  The format document in Japanese and English, sample reference files, and DocC guides.
- 手元で試すための `stacknest-fake-server` と `stacknest-kit-probe`（`Samples`）。
  `stacknest-fake-server` and `stacknest-kit-probe` for trying the kit locally (`Samples`).
