import Foundation
import StackNestViewerKit

/// 開いた StackNest の本（ビューアが持っておくもの）。
struct OpenedStackNestBook {
    let session: StackNestBookSession
    let reporter: StackNestProgressReporter
    let pageCount: Int
    let startPage: Int
}

/// StackNest の参照ファイルを開く。Info.plist には StackNestViewerSupport（referenceFormatVersions = [1]）・
/// 参照ファイルの型の取り込み・127.0.0.1 への平文の HTTP（NSAllowsLocalNetworking）・外への接続の許可が要る。
@MainActor
func openStackNestBook(
    at url: URL, configuration: StackNestBookSession.Configuration = .init(),
    showNotice: @escaping @MainActor (String) -> Void
) async throws -> OpenedStackNestBook {
    // 参照ファイル（数百バイト）は同期に読む。応答しないボリュームの上にありうるなら、ブロックしてよいスレッドで作る。
    // 既定では 127.0.0.1 と ::1 にしかつながない。
    let session = try StackNestBookSession(contentsOf: url, configuration: configuration)
    let manifest = try await session.manifest()  // 最初に読む（StackNest が読み込みに気づく）
    let start = StackNestBookReference.clampedStartPage(session.reference.startPage, pageCount: manifest.pageCount)
    let reporter = StackNestProgressReporter(session: session, startPage: start) { error in
        showNotice(error.message())  // 既定の英日の文言
    }
    return OpenedStackNestBook(session: session, reporter: reporter, pageCount: manifest.pageCount, startPage: start)
}

/// ページを表示する（`page` は StackNest のページ番号）。
@MainActor
func showPage(_ page: Int, of book: OpenedStackNestBook) async throws -> StackNestPage {
    let result = try await book.session.page(page)
    book.reporter.note(page: page)
    book.session.prefetch([page + 1, page + 2])  // 読む向きの近い順に
    return result
}

/// 閉じる。
@MainActor
func closeStackNestBook(_ book: OpenedStackNestBook) {
    book.reporter.close()
    book.session.close()
}
