import Foundation
import Testing

@testable import StackNestViewerKitCore

/// 作る側（StackNest が参照ファイルを書く）。作った参照ファイルが必ず読めること、バイト列が golden と一致すること、
/// 部品を使わない古い読み手でも読めることを固定する。
@Suite("参照ファイルを作る")
struct StackNestBookReferenceEncodingTests {
    static let goldenBook = URL(string: "http://127.0.0.1:51234/api/v1/libraries/00000000-0000-4000-8000-000000000001/books/42")!

    static func goldenReference() throws -> StackNestBookReference {
        try StackNestBookReference(
            version: 1, title: "Example Book", bookURL: goldenBook, token: "example-token-not-a-secret",
            expiresAt: try Date("2027-01-15T08:00:00Z", strategy: .iso8601), pageCount: 180,
            direction: .rightToLeft, startPage: 41)
    }

    @Test("golden: 固定の入力の encodedJSON() が Documentation/Samples/reference-v1.stacknestbook とバイト単位で一致する")
    func encodedJSONMatchesGolden() throws {
        let golden = try DocumentationSamples.data("reference-v1.stacknestbook")
        #expect(try Self.goldenReference().encodedJSON() == golden)
        #expect(golden.count == 334)
    }

    @Test("golden: 部品より前の読み手（凍結した写し）が golden を読める")
    func legacyReaderReadsGolden() throws {
        let legacy = try LegacyReferenceReader.parse(try DocumentationSamples.data("reference-v1.stacknestbook"))
        #expect(legacy == LegacyReferenceReader.Reference(
            version: 1, title: "Example Book", bookURL: Self.goldenBook, token: "example-token-not-a-secret",
            expiresAt: try Date("2027-01-15T08:00:00Z", strategy: .iso8601), pageCount: 180, direction: "rtl",
            startPage: 41))
    }

    @Test("作る → 読むの往復（IPv6 の区域 ID・日本語の題名・スラッシュ）")
    func roundTrips() throws {
        let reference = try StackNestBookReference(
            version: 1, title: "日本語の題名 / \"引用\"", bookURL: URL(string: "http://[fe80::1%25en0]:51234/api/v1/relay/abc")!,
            token: "q8Zk3nJ0r4bW-_sYt1uVw2xYz3aBcDeFgHiJkLmNoPq", expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            pageCount: 0, direction: .leftToRight, startPage: 0)
        let data = try reference.encodedJSON()
        #expect(try StackNestBookReference.parse(data) == reference)
        #expect(String(decoding: data, as: UTF8.self).contains(#"\/"#) == false, "スラッシュをエスケープしない")
        #expect(try LegacyReferenceReader.parse(data).bookURL == reference.bookURL)
    }

    @Test("小数秒は書かない（読み直すと秒に切り捨てた時刻になる）")
    func dropsFractionalSeconds() throws {
        let reference = try StackNestBookReference(
            version: 1, title: "t", bookURL: Self.goldenBook, token: "t", expiresAt: Date(timeIntervalSince1970: 1_800_000_000.75),
            pageCount: 1, direction: .rightToLeft, startPage: 0)
        let text = String(decoding: try reference.encodedJSON(), as: UTF8.self)
        #expect(text.contains(#""expiresAt" : "2027-01-15T08:00:00Z""#))
    }

    @Test("読んだ参照ファイルに direction が無ければ、書き直しても direction を書かない")
    func omitsMissingDirection() throws {
        let parsed = try StackNestBookReference.parse(StackNestBookReferenceTests.json(removing: ["direction"]))
        let object = try JSONSerialization.jsonObject(with: try parsed.encodedJSON()) as? [String: Any]
        #expect(object?["direction"] == nil)
        #expect(object?["format"] as? String == "stacknest-book-reference")
    }
}

/// `Documentation/Samples` のサンプルの参照ファイル（形式の文書が示すもの）を全件読み、期待どおりの結果になること。
@Suite("文書のサンプル")
struct DocumentationSampleTests {
    @Test("置いてあるサンプルはこの一覧と一致する（文書と試験がずれない）")
    func samplesAreAllCovered() throws {
        #expect(try DocumentationSamples.fileNames() == [
            "reference-credentials.stacknestbook", "reference-expired.stacknestbook",
            "reference-ipv6-zone.stacknestbook", "reference-lan-host.stacknestbook",
            "reference-malformed.stacknestbook", "reference-v1-unknown-keys.stacknestbook",
            "reference-v1.stacknestbook", "reference-v2.stacknestbook",
        ])
    }

    @Test("読めるサンプル")
    func readableSamples() throws {
        let unknown = try StackNestBookReference.parse(try DocumentationSamples.data("reference-v1-unknown-keys.stacknestbook"))
        #expect(unknown.direction == .leftToRight)
        #expect(unknown.pageCount == 24)
        let expired = try StackNestBookReference.parse(try DocumentationSamples.data("reference-expired.stacknestbook"))
        #expect(expired.isExpired())
        let zone = try StackNestBookReference.parse(try DocumentationSamples.data("reference-ipv6-zone.stacknestbook"))
        #expect(zone.bookURL.host(percentEncoded: false) == "fe80::1%en0")
        let lan = try StackNestBookReference.parse(try DocumentationSamples.data("reference-lan-host.stacknestbook"))
        #expect(lan.bookURL.host(percentEncoded: false) == "192.0.2.1", "形式はホストを絞らない（絞るのはセッション）")
    }

    @Test("読めないサンプル")
    func unreadableSamples() throws {
        #expect(throws: StackNestViewerError(.unsupportedVersion, formatVersion: 2)) {
            try StackNestBookReference.parse(try DocumentationSamples.data("reference-v2.stacknestbook"))
        }
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference.parse(try DocumentationSamples.data("reference-malformed.stacknestbook"))
        }
        #expect(throws: StackNestViewerError(.invalidReference)) {
            try StackNestBookReference.parse(try DocumentationSamples.data("reference-credentials.stacknestbook"))
        }
    }
}
