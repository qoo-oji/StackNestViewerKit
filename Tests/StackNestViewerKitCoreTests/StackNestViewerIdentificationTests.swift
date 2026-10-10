import Foundation
import Testing

@testable import StackNestViewerKitCore

/// 名乗り（`X-StackNest-Viewer`）。送る側と受ける側が 1 つの定義で、`headerValue` が出す値は必ず `parse` で読める。
@Suite("名乗り")
struct StackNestViewerIdentificationTests {
    @Test("形: <bundle id>/<版>; format=<版>; kit=<部品の版>（format → kit の順）")
    func headerShape() {
        let id = StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: "1.80", format: 1,
                                               kitVersion: "0.1.0")
        #expect(id.headerValue == "com.example.viewer/1.80; format=1; kit=0.1.0")
        #expect(StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: "1.80", format: 1)
                    .kitVersion == StackNestViewerKitInfo.version)
        #expect(StackNestViewerIdentification(bundleIdentifier: "", version: nil, format: 2, kitVersion: nil)
                    .headerValue == "unknown; format=2")
    }

    @Test("送る側は改行・区切り・非 ASCII を _ にする（ヘッダの注入を防ぐ）")
    func headerInjectionIsNeutralized() {
        let injected = StackNestViewerIdentification(
            bundleIdentifier: "com.example.v\r\nX-Evil: 1", version: "1.0; é/\n2", format: 1, kitVersion: "0.1\r\n")
        let value = injected.headerValue
        #expect(!value.contains("\r") && !value.contains("\n"))
        #expect(value == "com.example.v__X-Evil__1/1.0_____2; format=1; kit=0.1__")
        #expect(value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E })
    }

    @Test("長さ: bundle id と版は 64 文字・部品の版は 16 文字で切り、全体は最長でも 200 文字に収まる")
    func lengthIsBounded() {
        let long = StackNestViewerIdentification(
            bundleIdentifier: String(repeating: "a", count: 500), version: String(repeating: "9", count: 500),
            format: 1, kitVersion: "0.1.0")
        #expect(long.headerValue.count == 64 + 1 + 64 + "; format=1".count + "; kit=0.1.0".count)
        // 最悪の形: 64 + "/" 1 + 64 + "; format=" 9 + Int.min の 20 文字 + "; kit=" 6 + 16 = 180 ≤ 200
        let worst = StackNestViewerIdentification(
            bundleIdentifier: String(repeating: "a", count: 500), version: String(repeating: "9", count: 500),
            format: Int.min, kitVersion: String(repeating: "k", count: 500))
        #expect(worst.headerValue.count == 180)
        #expect(worst.headerValue.count <= StackNestViewerIdentification.maxStoredLength)
        #expect(StackNestViewerIdentification.sanitizeForStorage(worst.headerValue) == worst.headerValue)
    }

    @Test("headerValue → parse の往復（_・+ を含む bundle id・64 文字の版・kit= の有無）")
    func headerValueRoundTripsThroughParse() {
        let cases = [
            StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: "1.80", format: 1),
            StackNestViewerIdentification(bundleIdentifier: "com.example_viewer+debug", version: "2.0-beta+7",
                                          format: 1, kitVersion: "0.1.0"),
            StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: String(repeating: "9", count: 64),
                                          format: 12, kitVersion: nil),
            StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: nil, format: nil, kitVersion: nil),
        ]
        for id in cases {
            #expect(StackNestViewerIdentification.parse(id.headerValue) == id, "\(id.headerValue)")
        }
        // 整えた後の値に戻る（置き換えの _ を含む）。
        let messy = StackNestViewerIdentification(bundleIdentifier: "com.example viewer", version: "1 0", format: 1)
        #expect(StackNestViewerIdentification.parse(messy.headerValue)
                == StackNestViewerIdentification(bundleIdentifier: "com.example_viewer", version: "1_0", format: 1))
    }

    @Test("kit= の有無で bundle id・版・format は同じに読める（部品を使わない名乗りも受ける）")
    func kitParameterIsOptional() {
        let without = StackNestViewerIdentification.parse("com.example.viewer/1.80; format=1")
        let with = StackNestViewerIdentification.parse("com.example.viewer/1.80; format=1; kit=0.1.0")
        #expect(without?.bundleIdentifier == with?.bundleIdentifier)
        #expect(without?.version == with?.version)
        #expect(without?.format == with?.format)
        #expect(without?.kitVersion == nil)
        #expect(with?.kitVersion == "0.1.0")
    }

    @Test("文書の形を読む（知らない引数は読み飛ばし、キーは大文字小文字を区別しない）")
    func parsesTheDocumentedShape() {
        #expect(StackNestViewerIdentification.parse("com.example.viewer/1.80; format=1")
                == StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: "1.80", format: 1, kitVersion: nil))
        #expect(StackNestViewerIdentification.parse("com.example.viewer")
                == StackNestViewerIdentification(bundleIdentifier: "com.example.viewer", version: nil, format: nil, kitVersion: nil))
        #expect(StackNestViewerIdentification.parse("com.example.viewer/; FORMAT=2; future=x")?.format == 2)
        #expect(StackNestViewerIdentification.parse("com.example.viewer/2.0;format=x")?.format == nil)
        #expect(StackNestViewerIdentification.parse("com.example.viewer/2.0 (beta); format=1")?.version == "2.0 (beta)")
        #expect(StackNestViewerIdentification.parse("Com.Example-Viewer/3")?.bundleIdentifier == "Com.Example-Viewer")
        let long = "com.example.viewer/" + String(repeating: "9", count: 100) + "; format=1"
        #expect(StackNestViewerIdentification.parse(long)?.version?.count == 64)
        #expect(StackNestViewerIdentification.parse(long)?.format == 1, "版を切っても format= は読む")
    }

    @Test("bundle id でないものは読まない")
    func rejectsWhatIsNotABundleIdentifier() {
        for value in [nil, "", "/1.0; format=1", "com example/1.0", "ビューア/1.0", "com@example/1.0"] as [String?] {
            #expect(StackNestViewerIdentification.parse(value) == nil, "\(String(describing: value))")
        }
    }

    @Test("保存の形: 印字できる ASCII だけ・前後の空白を落とす・200 文字")
    func sanitizeForStorage() {
        typealias ID = StackNestViewerIdentification
        #expect(ID.sanitizeForStorage(nil) == nil)
        #expect(ID.sanitizeForStorage("   ") == nil)
        #expect(ID.sanitizeForStorage(" com.example.viewer/1.0; format=1 ") == "com.example.viewer/1.0; format=1")
        #expect(ID.sanitizeForStorage("com.example\u{0}.viewer\r\n/1.0\u{7F}") == "com.example.viewer/1.0")
        #expect(ID.sanitizeForStorage(String(repeating: "a", count: 1000))?.count == 200)
    }

    @Test("このアプリの名乗り（Bundle.main）")
    func forMainBundle() {
        let id = StackNestViewerIdentification.forMainBundle(format: 1)
        #expect(id.bundleIdentifier == (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName))
        #expect(id.format == 1)
        #expect(id.kitVersion == StackNestViewerKitInfo.version)
    }
}

@Suite("対応の宣言（StackNestViewerSupport）")
struct StackNestViewerSupportTests {
    static func plist(_ versionsXML: String) throws -> [String: Any] {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.example.viewer</string>
          <key>StackNestViewerSupport</key>
          <dict><key>referenceFormatVersions</key>\(versionsXML)</dict>
        </dict></plist>
        """
        let object = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
        return try #require(object as? [String: Any])
    }

    @Test("正の <integer> だけを宣言の順に読む（真偽値・実数・文字列・0 以下は捨てる）")
    func declaredVersionsKeepOnlyPositiveIntegers() throws {
        let info = try Self.plist(
            "<array><integer>2</integer><true/><real>1</real><string>1</string><integer>0</integer><integer>-1</integer><integer>1</integer></array>")
        #expect(StackNestViewerSupport.declaredVersions(in: info) == [2, 1])
        #expect(StackNestViewerSupport.declaredVersions(in: [:]) == [])
        #expect(StackNestViewerSupport.declaredVersions(in: ["StackNestViewerSupport": "1"]) == [])
    }

    @Test("宣言と書ける版の共通の最大")
    func choosesTheHighestCommonVersion() {
        #expect(StackNestViewerSupport.chooseVersion(declared: [1, 2, 3], writable: [1, 2]) == 2)
        #expect(StackNestViewerSupport.chooseVersion(declared: [3, 1], writable: [1, 2, 3]) == 3)
        #expect(StackNestViewerSupport.chooseVersion(declared: [2], writable: [1]) == nil)
        #expect(StackNestViewerSupport.chooseVersion(declared: [], writable: [1]) == nil)
        #expect(StackNestViewerSupport.chooseVersion(declared: [1], writable: StackNestFormat.supportedVersions) == 1)
    }

    @Test("自己点検: 正しい宣言は空、4 種類の問題をそれぞれ見つける")
    func verifyFindsEveryIssue() throws {
        #expect(StackNestViewerSupport.verify(infoDictionary: try Self.plist("<array><integer>1</integer></array>")).isEmpty)
        #expect(StackNestViewerSupport.verify(infoDictionary: ["CFBundleIdentifier": "x"]) == [.missingKey])
        #expect(StackNestViewerSupport.verify(infoDictionary: ["StackNestViewerSupport": [1]]) == [.malformedDeclaration])
        #expect(StackNestViewerSupport.verify(infoDictionary: try Self.plist("<string>1</string>")) == [.malformedDeclaration])
        #expect(StackNestViewerSupport.verify(infoDictionary: try Self.plist("<array><true/></array>")) == [.noVersionDeclared])
        #expect(StackNestViewerSupport.verify(infoDictionary: try Self.plist("<array><integer>1</integer><integer>2</integer></array>"))
                == [.declaresUnreadableVersion(2)])
        #expect(StackNestViewerSupport.verify(infoDictionary: try Self.plist("<array><integer>2</integer></array>"),
                                              readableVersions: [1, 2]).isEmpty)
    }
}
