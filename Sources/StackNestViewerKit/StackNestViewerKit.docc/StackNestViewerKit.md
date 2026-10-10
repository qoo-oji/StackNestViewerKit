# ``StackNestViewerKit``

StackNest の本を外部ビューアで読み、読書位置を StackNest へ書き戻すための部品。

A kit for reading StackNest books in an external viewer and writing the reading position back to StackNest.

## 概要 / Overview

StackNest は、対応したビューアへ本のファイルの代わりに参照ファイル（`.stacknestbook`）を渡す。ビューアは
``StackNestBookSession`` で参照ファイルを開き、manifest とページを 127.0.0.1 の StackNest から取り、
``StackNestProgressReporter`` で読み進めたページを書き戻す。同期の読み出し API を持つビューアは
``StackNestBlockingReader`` を使う。形式の型（``StackNestBookReference`` など）は `StackNestViewerKitCore` にあり、
`import StackNestViewerKit` だけで使える。

StackNest hands a supporting viewer a reference file (`.stacknestbook`) instead of the book's file. The viewer
opens it with ``StackNestBookSession``, fetches the manifest and pages from StackNest on 127.0.0.1, and writes
the reading position back with ``StackNestProgressReporter``. Viewers with a synchronous reading API use
``StackNestBlockingReader``. The format types (such as ``StackNestBookReference``) live in
`StackNestViewerKitCore` and are available through `import StackNestViewerKit`.

## Topics

### ガイド / Guides

- <doc:GettingStarted>
- <doc:InfoPlistAndSandbox>
- <doc:ReadingPages>
- <doc:BlockingReaders>
- <doc:WritingProgress>
- <doc:ErrorsAndLocalization>
- <doc:Security>
- <doc:FormatVersions>

### 本を読む / Reading a Book

- ``StackNestBookSession``
- ``StackNestPage``
- ``StackNestRequestPriority``
- ``StackNestHostPolicy``
- ``StackNestBlockingReader``
- ``StackNestPageNaming``

### 読書位置の書き戻し / Writing Progress

- ``StackNestProgressReporter``
- ``StackNestProgressRegistry``
