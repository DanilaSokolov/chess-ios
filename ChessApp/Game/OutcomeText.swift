import ChessCore
import ChessNet
import Foundation

/// The words for how a game ended, shared by the game screen and the history.

/// "You won", "You lost", "Draw", from the side of the player who played `color`.
func resultText(_ result: GameResult, for color: PieceColor) -> String {
    switch result {
    case .draw: String(localized: "Draw")
    case .unknown: String(localized: "Game interrupted")
    case .whiteWins, .blackWins:
        (result == .whiteWins) == (color == .white) ? String(localized: "You won") : String(localized: "You lost")
    }
}

extension Termination {
    /// Why the game ended, to follow the result: "You won · checkmate".
    var text: String {
        switch self {
        case .checkmate: String(localized: "checkmate")
        case .stalemate: String(localized: "stalemate")
        case .insufficientMaterial: String(localized: "insufficient material")
        case .threefoldRepetition: String(localized: "threefold repetition")
        case .fiftyMoveRule: String(localized: "fifty-move rule")
        case .resignation: String(localized: "resignation")
        case .abandonment: String(localized: "the player did not come back after disconnecting")
        case .timeout: String(localized: "time ran out")
        case .drawAgreement: String(localized: "by agreement")
        case .unknown: String(localized: "no connection to the server")
        }
    }
}
