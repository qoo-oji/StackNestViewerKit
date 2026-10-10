import Foundation
import Testing

@testable import StackNestViewerKit

@Suite("つなぐ宛先の制限・ページの仮の名前")
struct StackNestValueTypeTests {
    @Test("既定は 127.0.0.1 と ::1 の字面だけ")
    func loopbackOnlyAllowsLiteralLoopback() {
        let policy = StackNestHostPolicy.loopbackOnly
        #expect(policy.allows(URL(string: "http://127.0.0.1:51234/api/v1/x")!))
        #expect(policy.allows(URL(string: "http://[::1]:51234/api/v1/x")!))
        #expect(!policy.allows(URL(string: "http://192.0.2.1:51234/api/v1/x")!))
        #expect(!policy.allows(URL(string: "http://books.example.com/api/v1/x")!))
    }

    @Test("loopback の別の書き方・名前は既定で通さない（名前の解決や書き方の違いで別の宛先にされない）")
    func loopbackPolicyRejectsEquivalentSpellings() {
        for spelling in ["localhost", "LOCALHOST", "127.1", "0x7f.0.0.1", "127.0.0.1.", "[0:0:0:0:0:0:0:1]",
                         "[::ffff:127.0.0.1]", "127.0.0.2", "[fe80::1%25lo0]"] {
            let url = URL(string: "http://\(spelling):51234/api/v1/x")!
            #expect(!StackNestHostPolicy.loopbackOnly.allows(url), "\(spelling)")
        }
    }

    @Test("明示して広げる（大文字小文字・角括弧を問わない）・制限しない")
    func widenedPolicies() {
        let widened = StackNestHostPolicy.loopback(plus: ["Books.Example.com", "[fe80::1%en0]"])
        #expect(widened.allows(URL(string: "http://books.example.com/x")!))
        #expect(widened.allows(URL(string: "http://[fe80::1%25en0]:1/x")!))
        #expect(widened.allows(URL(string: "http://127.0.0.1/x")!))
        #expect(!widened.allows(URL(string: "http://192.0.2.1/x")!))
        #expect(StackNestHostPolicy.any.allows(URL(string: "http://192.0.2.1/x")!))
        #expect(!StackNestHostPolicy.any.allows(URL(string: "file:///tmp/x")!), "ホストの無い URL は通さない")
    }

    @Test("ページの仮の名前: 6 桁のゼロ埋め + .jpg。往復でき、それ以外の形は番号にしない")
    func pageNames() {
        #expect(StackNestPageNaming.entryName(forPage: 0) == "000000.jpg")
        #expect(StackNestPageNaming.entryName(forPage: 41) == "000041.jpg")
        #expect(StackNestPageNaming.pageIndex(fromEntryName: "000041.jpg") == 41)
        #expect(StackNestPageNaming.entryName(forPage: StackNestFormat.maxPageCount - 1) == "099999.jpg")
        #expect(StackNestPageNaming.entryName(forPage: 5_000_000_000) == "5000000000.jpg")
        #expect(StackNestPageNaming.pageIndex(fromEntryName: "5000000000.jpg") == 5_000_000_000)
        for other in ["41.jpg", "000041.png", "00004a.jpg", "../000001.jpg", "-00001.jpg", ".jpg", "000041.JPG"] {
            #expect(StackNestPageNaming.pageIndex(fromEntryName: other) == nil, "\(other)")
        }
        #expect(StackNestPageNaming.entryNames(pageCount: 3) == ["000000.jpg", "000001.jpg", "000002.jpg"])
        #expect(StackNestPageNaming.entryNames(pageCount: -1).isEmpty)
    }
}
