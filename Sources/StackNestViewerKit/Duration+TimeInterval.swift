import Foundation

extension Duration {
    /// `URLRequest.timeoutInterval` やタイマーに渡す秒数。`components` を経由しないので、`Int64.max` 秒を超える
    /// 長さでも落ちない（巨大な待ち時間を「上限なし」の意味で渡すホストがある）。
    var timeInterval: TimeInterval {
        self / .seconds(1)
    }
}
