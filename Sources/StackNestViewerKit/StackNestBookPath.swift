import Foundation

/// `book` のパスの形の検査。StackNest が書く基点は 2 つの形だけ:
///   - ローカルの書庫の本: `/api/v1/libraries/<library>/books/<id>`
///   - 中継するリモートの本: `/api/v1/relay/<relayID>`
/// 宛先の制限（`StackNestHostPolicy`）はホストしか見ないので、書き換えた参照ファイルの `book` が 127.0.0.1 の
/// 別のサービスの道（`/admin` など）を指すと、鍵の付いた決まった形の要求（`GET …/manifest`・`POST …/progress` など）を
/// そのサービスへ送ってしまう。セッションは、この形のときだけ要求を出す（`allowsAnyBookPath` で外せる）。
///
/// 形式（Core）では絞らない: 参照ファイルの型は作る側（StackNest）と共有で、形式の文書は `book` を「本の API の
/// 基点」としか決めていない（StackNest が別の形の基点を書く日が来ても、作る側と古い読み手が壊れないように）。
enum StackNestBookPath {
    /// パーセントエンコードしたままのパスで見る（`%2E%2E`・`%2F` を復号してから見ると、サーバが別の道として
    /// 解くものを通しうる）。区切りの間は空でなく、`.`・`..` でなく、URL の予約されていない文字（英数字と `-._~`）
    /// だけからなる（`%` を含む区切りは通さない）。末尾のスラッシュは 1 つだけ許す（要求を組み立てるときに外す）。
    static func isStackNestShape(_ url: URL) -> Bool {
        var path = url.absoluteURL.path(percentEncoded: true)
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return false }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy(isPlainSegment) else { return false }
        switch segments.count {
        case 4: return segments[0] == "api" && segments[1] == "v1" && segments[2] == "relay"
        case 6: return segments[0] == "api" && segments[1] == "v1" && segments[2] == "libraries" && segments[4] == "books"
        default: return false
        }
    }

    private static func isPlainSegment(_ segment: Substring) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~": return true
            default: return false
            }
        }
    }
}
