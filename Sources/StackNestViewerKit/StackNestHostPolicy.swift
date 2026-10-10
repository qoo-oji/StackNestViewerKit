import Foundation

/// つないでよいホスト。既定（`loopbackOnly`）は `127.0.0.1` と `::1` の IP の字面だけで、名前の `localhost` や
/// 同じ宛先の別の書き方（`127.1`・`::ffff:127.0.0.1` など）は含めない（参照ファイルが書き換えられても、鍵を
/// LAN や外の宛先へ送らない）。
///
/// Hosts the session may connect to. The default, `loopbackOnly`, accepts only the literal IP addresses
/// `127.0.0.1` and `::1` — not the name `localhost` or other spellings of loopback — so a tampered reference
/// file can't send the token to the LAN or the internet.
public struct StackNestHostPolicy: Sendable, Equatable {
    private enum Rule: Sendable, Equatable {
        case loopback(plus: Set<String>)
        case any
    }

    private let rule: Rule

    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1"]

    /// `127.0.0.1` と `::1` だけ（既定）。 / Only `127.0.0.1` and `::1` (the default).
    public static let loopbackOnly = StackNestHostPolicy(rule: .loopback(plus: []))

    /// loopback に加えて、明示したホスト（IP の字面かホスト名。大文字小文字を区別しない。IPv6 の角括弧は省いてよい）。
    ///
    /// Loopback plus the listed hosts (IP literals or names, case-insensitive; IPv6 brackets optional).
    public static func loopback(plus hosts: Set<String>) -> StackNestHostPolicy {
        let normalized = hosts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() }
        return StackNestHostPolicy(rule: .loopback(plus: Set(normalized)))
    }

    /// 制限しない（ホストが自分の責任で選ぶ。部品の既定にはしない）。 / No restriction (the host's own choice).
    public static let any = StackNestHostPolicy(rule: .any)

    /// `url` のホストへつないでよいか。 / Whether the session may connect to `url`'s host.
    public func allows(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        switch rule {
        case .any: return true
        case .loopback(let extra): return Self.loopbackHosts.contains(host) || extra.contains(host)
        }
    }
}
