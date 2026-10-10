// swift-tools-version: 6.2
// 部品を手元で試すための道具（部品のパッケージとは別。部品は `..` から取り込む）:
//   - stacknest-fake-server: 127.0.0.1 の本物のソケットで、フォルダの画像を本として配る偽の StackNest
//   - stacknest-kit-probe: 参照ファイルを 1 つ受け取り、manifest → 開くページ → progress を試す
//   - HostMode*: ホストの言語設定の組み合わせで、README の統合例を警告をエラーにしてコンパイルする
// 部品のパッケージの名前を明示する（パスで取り込むと、識別子が置き場のディレクトリの名前になり、手元と CI で違うため）。
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "StackNestViewerKitSamples",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "stacknest-fake-server", targets: ["FakeServerCommand"]),
        .executable(name: "stacknest-kit-probe", targets: ["KitProbeCommand"]),
    ],
    dependencies: [.package(name: "StackNestViewerKit", path: "..")],
    targets: [
        .target(name: "FakeStackNestServer",
                dependencies: [.product(name: "StackNestViewerKitCore", package: "StackNestViewerKit")]),
        .executableTarget(name: "FakeServerCommand", dependencies: ["FakeStackNestServer"]),
        .target(name: "KitProbe", dependencies: [.product(name: "StackNestViewerKit", package: "StackNestViewerKit")]),
        .executableTarget(name: "KitProbeCommand", dependencies: ["KitProbe"]),
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
        .testTarget(name: "SamplesTests",
                    dependencies: ["FakeStackNestServer", "KitProbe",
                                   .product(name: "StackNestViewerKit", package: "StackNestViewerKit"),
                                   .product(name: "StackNestViewerKitTesting", package: "StackNestViewerKit")]),
    ]
)
