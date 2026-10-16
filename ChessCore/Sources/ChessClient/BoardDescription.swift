import ChessCore
import Foundation

/// The board in words, for VoiceOver. Square names (e2, f6) are the same in
/// every language and are not translated.
public enum BoardDescription {
    /// "white pawn". Colour and piece are translated together, not glued
    /// from two words: in Russian the adjective agrees with the piece's gender.
    public static func pieceName(_ piece: Piece) -> String {
        switch (piece.color, piece.kind) {
        case (.white, .pawn): String(localized: "white pawn", bundle: .module)
        case (.white, .knight): String(localized: "white knight", bundle: .module)
        case (.white, .bishop): String(localized: "white bishop", bundle: .module)
        case (.white, .rook): String(localized: "white rook", bundle: .module)
        case (.white, .queen): String(localized: "white queen", bundle: .module)
        case (.white, .king): String(localized: "white king", bundle: .module)
        case (.black, .pawn): String(localized: "black pawn", bundle: .module)
        case (.black, .knight): String(localized: "black knight", bundle: .module)
        case (.black, .bishop): String(localized: "black bishop", bundle: .module)
        case (.black, .rook): String(localized: "black rook", bundle: .module)
        case (.black, .queen): String(localized: "black queen", bundle: .module)
        case (.black, .king): String(localized: "black king", bundle: .module)
        }
    }

    /// What VoiceOver reads for a square: "e2, white pawn" or "e4, empty".
    public static func square(_ square: Square, piece: Piece?) -> String {
        if let piece {
            String(localized: "\(square.name), \(pieceName(piece))", bundle: .module)
        } else {
            String(localized: "\(square.name), empty", bundle: .module)
        }
    }

    /// The square's state, read after its name: "selected, last move".
    /// Nil when there is nothing to say.
    public static func state(isSelected: Bool, isTarget: Bool, isCapture: Bool, isLastMove: Bool) -> String? {
        var parts: [String] = []
        if isSelected { parts.append(String(localized: "selected", bundle: .module)) }
        if isTarget {
            parts.append(
                isCapture
                    ? String(localized: "capture", bundle: .module)
                    : String(localized: "possible move", bundle: .module))
        }
        if isLastMove { parts.append(String(localized: "last move", bundle: .module)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Spoken when the opponent moves: "Opponent: black knight from g8 to f6".
    /// `piece` is what stands on the target square after the move, so a
    /// promotion is announced as the new piece.
    public static func opponentMove(_ move: Move, piece: Piece, givesCheck: Bool) -> String {
        let moved = String(
            localized: "Opponent: \(pieceName(piece)) from \(move.from.name) to \(move.to.name)", bundle: .module)
        return givesCheck ? String(localized: "\(moved). Check!", bundle: .module) : moved
    }
}
