// swift-tools-version: 6.2
// 部品を手元で試すための道具（部品のパッケージとは別。部品は `..` から取り込む）:
//   - HostMode*: ホストの言語設定の組み合わせで、README の統合例を警告をエラーにしてコンパイルする
// 部品のパッケージの名前を明示する（パスで取り込むと、識別子が置き場のディレクトリの名前になり、手元と CI で違うため）。
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "StackNestViewerKitSamples",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "StackNestViewerKit", path: "..")],
    targets: [
        // ①MainActor 既定＋nonisolated(nonsending) 既定（Xcode の Approachable Concurrency のアプリと同じ）
        .target(name: "HostModeMainActor",
                dependencies: [.product(name: "StackNestViewerKit", package: "StackNestViewerKit")],
                swiftSettings: strict + [.defaultIsolation(MainActor.self),
                                         .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        // ②Swift 5 の言語モード（MainActor 既定と組み合わせるアプリもある）
        .target(name: "HostModeSwift5",
                dependencies: [.product(name: "StackNestViewerKit", package: "StackNestViewerKit")],
                swiftSettings: strict + [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]),
        // ③Swift 6 の既定
        .target(name: "HostModeSwift6",
                dependencies: [.product(name: "StackNestViewerKit", package: "StackNestViewerKit")],
                swiftSettings: strict),
    ]
)
