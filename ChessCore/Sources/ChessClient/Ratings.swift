import ChessNet

extension TimeControl {
    /// How long a game is expected to last, in seconds: the initial time plus
    /// 40 increments (a game of about 40 moves each). The server sorts games
    /// into rating categories by it, as Lichess does.
    public var estimatedSeconds: Int { initialSeconds + 40 * incrementSeconds }

    /// The rating a game with this time control counts for. The thresholds
    /// are the server's (`RatingCategory` in history.proto): under 3 minutes
    /// bullet, under 8 blitz, under 25 rapid, else classical.
    public var ratingCategory: RatingCategory {
        switch estimatedSeconds {
        case ..<180: .bullet
        case ..<480: .blitz
        case ..<1500: .rapid
        default: .classical
        }
    }
}

extension RatingCategory {
    /// The categories `timeControls` fall into, each once, fastest first:
    /// the ratings the lobby shows.
    public static func categories(of timeControls: [TimeControl]) -> [RatingCategory] {
        Set(timeControls.map(\.ratingCategory)).sorted()
    }
}

/// "1520", or "1520?" while the rating is provisional. A category without
/// rated games has no rating yet: everyone starts at 1500, so "1500?".
/// Digits only, the same in every language.
public func ratingText(_ rating: Rating?) -> String {
    guard let rating else { return "\(Int(Rating.initial))?" }
    let value = Int(rating.rating.rounded())
    return rating.isProvisional ? "\(value)?" : "\(value)"
}

/// "+12", "−8" (a real minus sign) or "±0": how a game moved a rating.
public func ratingChangeText(_ change: Int) -> String {
    if change > 0 { return "+\(change)" }
    if change < 0 { return "\u{2212}\(-change)" }
    return "\u{00B1}0"
}
