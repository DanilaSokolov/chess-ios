import ChessCore
import SwiftUI

/// An 8×8 board. Tap a piece to select it, then tap a highlighted square,
/// or drag the piece onto the square. Both end in the same `onMove`; the
/// server validates the move either way.
struct BoardView: View {
    let position: Position
    /// The side shown at the bottom.
    let perspective: PieceColor
    var lastMove: Move?
    var isInteractive = true
    var onMove: (Move) -> Void = { _ in }

    @State private var picker = MovePicker()
    @State private var promotionChoices: [Move] = []
    /// Resets by itself if the system cancels the gesture (a call, Control
    /// Center), so a lifted piece never gets stuck.
    @GestureState private var drag: Drag?

    /// A press on the board. It becomes a drag once the pointer moves past
    /// `liftDistance` while holding a piece of the side to move.
    private struct Drag {
        var from: Square
        var location: CGPoint
        var isLifted: Bool
    }

    private static let liftDistance: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) / 8
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { column in
                            let square = self.square(atRow: row, column: column)
                            SquareView(
                                square: square,
                                piece: position[square],
                                size: size,
                                isSelected: square == picker.selected,
                                isTarget: targets.contains(square),
                                isLifted: liftedFrom == square,
                                isHovered: hoveredSquare(size: size) == square,
                                isLastMove: lastMove?.from == square || lastMove?.to == square,
                                isCheckedKing: isCheckedKing(square),
                                showsFile: row == 7,
                                showsRank: column == 0
                            )
                            .chessSquareAccessibility(
                                square: square, piece: position[square], sideToMove: position.sideToMove,
                                isSelected: square == picker.selected, isTarget: targets.contains(square),
                                isLastMove: lastMove?.from == square || lastMove?.to == square,
                                isInteractive: isInteractive
                            ) { tap(square) }
                        }
                    }
                }
            }
            .frame(width: size * 8, height: size * 8)
            .overlay(alignment: .topLeading) { liftedPiece(size: size) }
            .contentShape(Rectangle())
            .gesture(boardGesture(size: size))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: position) { picker.selected = nil }
        .promotionDialog($promotionChoices, onMove: onMove)
    }

    /// The lifted piece shows its targets just like a selected one.
    private var targets: Set<Square> { picker.targets(from: liftedFrom ?? picker.selected, in: position) }

    private func square(atRow row: Int, column: Int) -> Square {
        Square.at(row: row, column: column, from: perspective)
    }

    private func isCheckedKing(_ square: Square) -> Bool {
        position[square] == Piece(position.sideToMove, .king) && position.isInCheck
    }

    // MARK: - Drag and drop

    private var liftedFrom: Square? {
        drag.flatMap { $0.isLifted ? $0.from : nil }
    }

    private func hoveredSquare(size: CGFloat) -> Square? {
        guard let drag, drag.isLifted else { return nil }
        return square(at: drag.location, size: size)
    }

    /// The board square under `point`, in board coordinates.
    private func square(at point: CGPoint, size: CGFloat) -> Square? {
        let column = Int((point.x / size).rounded(.down))
        let row = Int((point.y / size).rounded(.down))
        guard (0..<8).contains(column), (0..<8).contains(row) else { return nil }
        return square(atRow: row, column: column)
    }

    @ViewBuilder
    private func liftedPiece(size: CGFloat) -> some View {
        if let drag, drag.isLifted, let piece = position[drag.from] {
            PieceGlyph(piece: piece, size: size * 1.15)
                .position(drag.location)
                .allowsHitTesting(false)
        }
    }

    /// One gesture for the whole board: a press that barely moves is a tap,
    /// anything longer that starts on a movable piece is a drag.
    private func boardGesture(size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($drag) { value, state, _ in
                guard isInteractive, let from = square(at: value.startLocation, size: size) else { return }
                let isLifted = state?.isLifted == true || liftsPiece(from: from, translation: value.translation)
                state = Drag(from: from, location: value.location, isLifted: isLifted)
            }
            .onEnded { value in
                guard isInteractive, let from = square(at: value.startLocation, size: size) else { return }
                if liftsPiece(from: from, translation: value.translation) {
                    drop(from: from, on: square(at: value.location, size: size))
                } else {
                    tap(from)
                }
            }
    }

    private func liftsPiece(from: Square, translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > Self.liftDistance
            && position[from]?.color == position.sideToMove
    }

    private func drop(from: Square, on target: Square?) {
        apply(picker.drop(from: from, on: target, in: position))
    }

    private func apply(_ outcome: MovePicker.Outcome) {
        switch outcome {
        case .move(let move): onMove(move)
        case .promotion(let moves): promotionChoices = moves
        case .none: break
        }
    }

    private func tap(_ square: Square) {
        guard isInteractive else { return }
        apply(picker.tap(square, in: position))
    }
}

private struct SquareView: View {
    let square: Square
    let piece: Piece?
    let size: CGFloat
    let isSelected: Bool
    let isTarget: Bool
    let isLifted: Bool
    let isHovered: Bool
    let isLastMove: Bool
    let isCheckedKing: Bool
    let showsFile: Bool
    let showsRank: Bool

    private var isLight: Bool { (square.file + square.rank) % 2 == 1 }

    var body: some View {
        ZStack {
            Rectangle().fill(isLight ? Color(BoardPalette.lightSquare) : Color(BoardPalette.darkSquare))
            if isLastMove {
                Rectangle().fill(Color.yellow.opacity(0.35))
            }
            if isSelected {
                Rectangle().fill(Color.green.opacity(0.4))
            }
            if isCheckedKing {
                RadialGradient(colors: [.red, .red.opacity(0)], center: .center, startRadius: 0, endRadius: size * 0.6)
            }
            if let piece {
                PieceGlyph(piece: piece, size: size)
                    .opacity(isLifted ? 0.3 : 1)
            }
            if isTarget {
                if piece == nil {
                    Circle().fill(Color.black.opacity(0.25)).frame(width: size * 0.3)
                } else {
                    Circle().stroke(Color.black.opacity(0.3), lineWidth: size * 0.08).padding(size * 0.04)
                }
            }
            if isHovered {
                Rectangle().strokeBorder(Color.white.opacity(0.8), lineWidth: size * 0.06)
            }
            coordinates
        }
        .frame(width: size, height: size)
    }

    private var coordinates: some View {
        let color = isLight ? Color(BoardPalette.darkSquare) : Color(BoardPalette.lightSquare)
        let font = Font.system(size: size * 0.16, weight: .semibold)
        return ZStack {
            if showsRank {
                Text(String(square.rank + 1)).font(font).foregroundStyle(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(size * 0.05)
            }
            if showsFile {
                Text(String(square.name.first!)).font(font).foregroundStyle(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size * 0.05)
            }
        }
    }
}

/// A piece glyph sized for a square of side `size`.
private struct PieceGlyph: View {
    let piece: Piece
    let size: CGFloat

    var body: some View {
        Text(piece.glyph)
            .font(.system(size: size * 0.78))
            .foregroundStyle(piece.color == .white ? Color.white : Color.black)
            .shadow(color: piece.color == .white ? .black : .clear, radius: 0.8)
            .shadow(color: piece.color == .white ? .black : .clear, radius: 0.8)
    }
}

#Preview {
    BoardView(position: .starting, perspective: .white, lastMove: Move(uci: "e2e4"))
        .padding()
}
