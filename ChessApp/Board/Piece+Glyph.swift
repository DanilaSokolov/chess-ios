import ChessCore

extension Piece {
    /// Solid Unicode chess glyph, forced to text presentation so the pawn is
    /// not drawn as an emoji.
    var glyph: String {
        let scalar: String =
            switch kind {
            case .king: "\u{265A}"
            case .queen: "\u{265B}"
            case .rook: "\u{265C}"
            case .bishop: "\u{265D}"
            case .knight: "\u{265E}"
            case .pawn: "\u{265F}"
            }
        return scalar + "\u{FE0E}"
    }
}
