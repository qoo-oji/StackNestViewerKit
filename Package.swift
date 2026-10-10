// swift-tools-version: 6.0
// StackNestViewerKit — 外部ビューアが StackNest の本の参照ファイル（.stacknestbook）を読むための部品。
// 依存パッケージは持たない（Foundation だけ）。3 つのプロダクトに分ける:
//   - StackNestViewerKitCore: 形式の型・宣言・名乗り・エラーと文言（通信を持たない）
//   - StackNestViewerKit: 本のセッション・同期の橋渡し・読書位置の書き戻し（Core を再輸出する）
//   - StackNestViewerKitTesting: ビューアの試験のための見立てとサンプル
// 分離はすべて明示する（defaultIsolation・NonisolatedNonsendingByDefault を設定しない）。取り込むホストの
// 設定に関わらず、部品の型の分離が変わらないようにするため。
import PackageDescription

let package = Package(
    name: "StackNestViewerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StackNestViewerKitCore", targets: ["StackNestViewerKitCore"]),
        .library(name: "StackNestViewerKit", targets: ["StackNestViewerKit"]),
        .library(name: "StackNestViewerKitTesting", targets: ["StackNestViewerKitTesting"]),
    ],
    targets: [
        .target(name: "StackNestViewerKitCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "StackNestViewerKit", dependencies: ["StackNestViewerKitCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "StackNestViewerKitTesting", dependencies: ["StackNestViewerKit"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "StackNestViewerKitCoreTests", dependencies: ["StackNestViewerKitCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "StackNestViewerKitTests",
                    dependencies: ["StackNestViewerKit", "StackNestViewerKitTesting"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        // @testable を使わず、ビューアが書くのと同じ公開 API だけで統合の形を書く。
        .testTarget(name: "StackNestViewerKitPublicAPITests",
                    dependencies: ["StackNestViewerKit", "StackNestViewerKitTesting"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        // 協調スレッドを飽和させる試験だけを置く（環境変数 STACKNEST_KIT_POOL_TEST=1 のときだけ走る。単独で走らせる）。
        .testTarget(name: "StackNestViewerKitPoolTests",
                    dependencies: ["StackNestViewerKit", "StackNestViewerKitTesting"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
