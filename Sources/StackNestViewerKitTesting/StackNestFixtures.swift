import Foundation
import StackNestViewerKit

/// 試験のためのサンプル（コードで作る。ファイルを同梱しない）。 / Test samples generated in code.
public enum StackNestFixtures {
    /// 形式の文書の例と同じ形の参照ファイルの JSON。`extraFields` の値は文字列として足す（知らない項目の試験）。
    ///
    /// Reference file JSON in the documented shape. `extraFields` adds string keys (for unknown-key tests).
    public static func referenceJSON(bookURL: URL, token: String = "fixture-token",
                                     expiresAt: Date = .distantFuture, pageCount: Int = 3,
                                     version: Int = 1, startPage: Int = 0,
                                     extraFields: [String: String] = [:]) -> Data
    {
        var object: [String: Any] = [
            "format": StackNestFormat.formatName, "version": version, "title": "Fixture",
            "book": bookURL.absoluteString, "token": token, "expiresAt": expiresAt.formatted(.iso8601),
            "pageCount": pageCount, "direction": "rtl", "startPage": startPage,
        ]
        for (key, value) in extraFields { object[key] = value }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// `directory` に `<title>.stacknestbook` として書く。 / Writes `<title>.stacknestbook` into `directory`.
    public static func writeReference(_ data: Data, in directory: URL, title: String = "Fixture") throws -> URL {
        let url = directory.appendingPathComponent(title).appendingPathExtension(StackNestFormat.fileExtension)
        try data.write(to: url)
        return url
    }

    /// 灰色の PNG（`width`×`height`・各画素の明るさが `marker`）。どのページの画像かを `marker(of:)` で見分けられる。
    /// 圧縮しない（大きな画像は大きなバイト列になる）。
    ///
    /// A grayscale PNG whose pixels all have the brightness `marker`, so `marker(of:)` can tell which page it is.
    /// The image data isn't compressed.
    ///
    /// `marker` は 0…255 の範囲に収まる値で、256 以上は 256 で一巡する（300 は 44 として読める）。ページ数が 255 を
    /// 超える見立てでは、255 番のページと表紙（255）、256 番と 0 番は見分けられない。大きな画像（例: 1600×2400）は、
    /// debug ビルドでは数秒から十数秒かかる。
    ///
    /// The marker is meant to be 0...255 and wraps modulo 256 (300 reads back as 44), so with more than 255
    /// pages page 255 can't be told from the cover (255) and page 256 not from page 0. Large images (such as
    /// 1600×2400) take several seconds in debug builds.
    public static func pngPage(width: Int = 4, height: Int = 6, marker: Int = 0) -> Data {
        let rows = (0..<height).map { _ -> [UInt8] in
            [0] + (0..<width).map { _ in UInt8(truncatingIfNeeded: marker) }
        }
        let raw = Data(rows.joined())
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + Data([8, 0, 0, 0, 0])))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        let typeBytes = Data(type.utf8)
        return bigEndian(UInt32(body.count)) + typeBytes + body + bigEndian(crc32(typeBytes + body))
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// 圧縮しない zlib（stored ブロック。1 つのブロックは 65,535 バイトまでなので、それを超えたら分ける）。
    private static func zlibStored(_ raw: Data) -> Data {
        var out = Data([0x78, 0x01])
        var offset = raw.startIndex
        repeat {
            let count = min(raw.endIndex - offset, Int(UInt16.max))
            let isLast = offset + count == raw.endIndex
            let length = UInt16(count)
            out.append(isLast ? 0x01 : 0x00)
            out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)])
            out.append(raw[offset..<(offset + count)])
            offset += count
        } while offset < raw.endIndex
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        out.append(bigEndian(b << 16 | a))
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// `pngPage(marker:)` の 1 画素目の明るさを読む。 / Reads the brightness `pngPage(marker:)` wrote.
    public static func marker(of png: Data) -> Int? {
        // IDAT の本文: zlib の見出し 2 バイト・stored ブロックの見出し 5 バイト・行の filter 1 バイトの次が 1 画素目。
        guard let start = png.range(of: Data("IDAT".utf8))?.upperBound, png.endIndex > start + 8 else { return nil }
        return Int(png[start + 8])
    }
}
