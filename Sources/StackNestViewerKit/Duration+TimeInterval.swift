import Foundation

extension Duration {
    /// `URLRequest.timeoutInterval` やタイマーに渡す秒数。
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
