import Foundation

/// `Documentation/Samples` の参照ファイル（形式の文書と同じ置き場。試験は全件を読む）。
enum DocumentationSamples {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // StackNestViewerKitCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // リポジトリの根
        .appendingPathComponent("Documentation/Samples", isDirectory: true)

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    /// 置いてあるファイルの名前（名前順）。
    static func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
    }
}
