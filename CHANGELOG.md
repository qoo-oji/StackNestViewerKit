# 変更履歴 / Changelog

注目すべき変更をすべてここに記録する。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、版は
[Semantic Versioning](https://semver.org/lang/ja/) に従う。各項目は日本語と英語で書く（GitHub Release の本文になる）。

All notable changes are recorded here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/). Each entry is written in Japanese and English; it becomes the GitHub
Release notes.

## [Unreleased]

### 変更 / Changed

- セッションは、`book` のパスが StackNest の書く形（`/api/v1/libraries/<library>/books/<id>` と `/api/v1/relay/<relayID>`）のときだけ要求を出し、ほかは要求を出さずに `invalidReference` で断る（`init(contentsOf:)` は開く時点で断る）。書き換えた参照ファイルで、鍵の付いた要求を 127.0.0.1 の別のサービスへ送らせないため。ほかの形の基点へつなぐホストは `Configuration.allowsAnyBookPath` で外せる。
  A session makes requests only when the `book` path has one of the shapes StackNest writes (`/api/v1/libraries/<library>/books/<id>` and `/api/v1/relay/<relayID>`), and otherwise fails with `invalidReference` without a request (`init(contentsOf:)` refuses when opening), so a tampered reference file can't send token-carrying requests to another service on 127.0.0.1. Hosts that connect to a base of another shape can turn this off with `Configuration.allowsAnyBookPath`.

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
