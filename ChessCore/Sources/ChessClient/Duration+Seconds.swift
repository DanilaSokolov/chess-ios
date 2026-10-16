import Foundation

/// `Duration` keeps seconds and attoseconds apart; Foundation APIs such as
/// `Date.addingTimeInterval` want one `TimeInterval`.
extension Duration {
    public var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
