import ChessCore
import SwiftUI

/// Tap-to-move logic shared by the 2D and 3D boards: tap a piece of the side
/// to move to select it, then tap one of its target squares.
struct MovePicker {
    enum Outcome: Equatable {
        case none
        case move(Move)
        /// A pawn reached the last rank: the player picks the piece.
        case promotion([Move])
    }

    var selected: Square?

    func targets(from square: Square?, in position: Position) -> Set<Square> {
        guard let square else { return [] }
        return Set(position.legalMoves(from: square).map(\.to))
    }

    mutating func tap(_ square: Square, in position: Position) -> Outcome {
        if let from = selected {
            let outcome = moves(from: from, to: square, in: position)
            if outcome != .none {
                selected = nil
                return outcome
            }
        }
        if position[square]?.color == position.sideToMove {
            selected = square == selected ? nil : square
        } else {
            selected = nil
        }
        return .none
    }

    /// A piece dragged from `from` and dropped on `target` (nil: off the board).
    mutating func drop(from: Square, on target: Square?, in position: Position) -> Outcome {
        guard let target, target != from else {
            // Dropped back on its square (keep it selected for a tap-move) or off the board.
            selected = target == nil ? nil : from
            return .none
        }
        selected = nil
        return moves(from: from, to: target, in: position)
    }

    private func moves(from: Square, to: Square, in position: Position) -> Outcome {
        let moves = position.legalMoves(from: from).filter { $0.to == to }
        switch moves.count {
        case 0: return .none
        case 1: return .move(moves[0])
        default: return .promotion(moves)
        }
    }
}

extension View {
    /// Asks which piece a pawn promotes to while `choices` is not empty.
    func promotionDialog(_ choices: Binding<[Move]>, onMove: @escaping (Move) -> Void) -> some View {
        confirmationDialog(
            "Promotion",
            isPresented: .init(
                get: { !choices.wrappedValue.isEmpty },
                set: { if !$0 { choices.wrappedValue = [] } }
            )
        ) {
            ForEach(choices.wrappedValue, id: \.self) { move in
                Button(promotionName(move.promotion)) { onMove(move) }
            }
        }
    }
}

private func promotionName(_ kind: PieceKind?) -> String {
    switch kind {
    case .queen: String(localized: "Queen")
    case .rook: String(localized: "Rook")
    case .bishop: String(localized: "Bishop")
    case .knight: String(localized: "Knight")
    default: "?"
    }
}
