import Testing

@testable import StackNestViewerKitCore

@Suite("部品の版")
struct StackNestViewerKitInfoTests {
    @Test("版は先頭が 0 でない X.Y.Z（リリースの検査が CHANGELOG とタグに突き合わせる形）")
    func versionIsSemantic() {
        let parts = StackNestViewerKitInfo.version.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        for part in parts {
            #expect(Int(part) != nil, "\(part)")
            #expect(part == "0" || !part.hasPrefix("0"), "\(part)")
        }
    }
}
