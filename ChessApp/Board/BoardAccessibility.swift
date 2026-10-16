import ChessClient
import ChessCore
import SwiftUI

extension Square {
    /// The square drawn at `row` (0 at the top) and `column` (0 at the left)
    /// when the board is seen from `perspective`'s side.
    static func at(row: Int, column: Int, from perspective: PieceColor) -> Square {
        // row and column come from 0..<8 loops, so the square always exists.
        perspective == .white
            ? Square(file: column, rank: 7 - row)!
            : Square(file: 7 - column, rank: row)!
    }
}

extension View {
    /// Makes one board square a VoiceOver element: "e2, white pawn", its
    /// state ("selected, possible move"), and a double-tap that does what a
    /// tap does. Both boards use it, so VoiceOver plays the same in 2D and 3D.
    func chessSquareAccessibility(
        square: Square, piece: Piece?, sideToMove: PieceColor,
        isSelected: Bool, isTarget: Bool, isLastMove: Bool, isInteractive: Bool,
        activate: @escaping () -> Void
    ) -> some View {
        let state = BoardDescription.state(
            isSelected: isSelected, isTarget: isTarget, isCapture: isTarget && piece != nil, isLastMove: isLastMove)
        let hint: LocalizedStringKey? =
            !isInteractive
            ? nil
            : isTarget
                ? "Double-tap to move here"
                : piece?.color == sideToMove && !isSelected
                    ? "Double-tap to choose this piece"
                    : nil
        return
            self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: BoardDescription.square(square, piece: piece)))
            .accessibilityValue(Text(verbatim: state ?? ""))
            .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { if isInteractive { activate() } }
    }
}

/// The 3D board for VoiceOver: a plain 8×8 grid laid over the scene, since
/// RealityKit entities are not accessibility elements.
struct AccessibleBoardGrid: View {
    let position: Position
    let perspective: PieceColor
    let selected: Square?
    let targets: Set<Square>
    let lastMove: Move?
    let isInteractive: Bool
    let activate: (Square) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { column in
                        let square = Square.at(row: row, column: column, from: perspective)
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .chessSquareAccessibility(
                                square: square, piece: position[square], sideToMove: position.sideToMove,
                                isSelected: square == selected, isTarget: targets.contains(square),
                                isLastMove: lastMove?.from == square || lastMove?.to == square,
                                isInteractive: isInteractive
                            ) { activate(square) }
                    }
                }
            }
        }
    }
}
