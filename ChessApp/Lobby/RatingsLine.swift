import ChessClient
import ChessNet
import SwiftUI

/// The player's ratings in the lobby, on one line: the category of the
/// selected time control first and larger, then the other categories the
/// lobby's time controls fall into. "Blitz 1520  Bullet 1480 · Rapid 1500?"
/// ("?" while a rating is provisional, and 1500? for a category not played yet).
struct RatingsLine: View {
    let ratings: [RatingCategory: Rating]
    /// The categories of the lobby's time controls.
    let categories: [RatingCategory]
    /// The selected time control's category.
    let selected: RatingCategory

    var body: some View {
        let others = categories.filter { $0 != selected }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(selected.title) \(ratingText(ratings[selected]))")
                .font(.headline.monospacedDigit())
            if !others.isEmpty {
                Text(verbatim: others.map { "\($0.title) \(ratingText(ratings[$0]))" }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Ratings: \(([selected] + others).map(spoken).joined(separator: ", "))"))
    }

    /// "Blitz 1520", or "Rapid 1500, provisional" rather than a question mark.
    private func spoken(_ category: RatingCategory) -> String {
        let rating = ratings[category]
        guard rating?.isProvisional ?? true else { return "\(category.title) \(ratingText(rating))" }
        let value = rating.map { Int($0.rating.rounded()) } ?? Int(Rating.initial)
        return String(localized: "\(category.title) \(value), provisional")
    }
}

extension RatingCategory {
    /// "Blitz", in the player's language.
    var title: String {
        switch self {
        case .bullet: String(localized: "Bullet")
        case .blitz: String(localized: "Blitz")
        case .rapid: String(localized: "Rapid")
        case .classical: String(localized: "Classical")
        }
    }
}
