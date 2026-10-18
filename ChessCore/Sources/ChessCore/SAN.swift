/// Standard Algebraic Notation (SAN), as in PGN: "e4", "Nbd7", "exd5",
/// "e8=Q+", "O-O-O", "Rd8#".
public enum SANError: Error, Sendable, Equatable {
    /// The move at `ply` (1 is White's first move) is not legal in the
    /// position reached by the moves before it.
    case illegalMove(ply: Int, uci: String)
}

extension Position {
    /// The move in SAN, or nil if it is not legal here.
    ///
    /// The piece's letter (none for a pawn), then just enough of the starting
    /// square to tell it from another piece of the same kind that could also
    /// go there: the file if that is enough, else the rank, else both. A pawn
    /// capture names the pawn's file ("exd5", also en passant). Promotion is
    /// "=Q", castling "O-O" and "O-O-O"; "+" marks check and "#" mate.
    public func san(_ move: Move) -> String? {
        guard let piece = self[move.from], isLegal(move) else { return nil }
        var text: String
        if piece.kind == .king, abs(move.to.file - move.from.file) == 2 {
            text = move.to.file > move.from.file ? "O-O" : "O-O-O"
        } else if piece.kind == .pawn {
            // A pawn changing file captures, en passant included (its target square is empty).
            let isCapture = move.from.file != move.to.file
            text = isCapture ? fileLetter(move.from) + "x" + move.to.name : move.to.name
            if let promotion = move.promotion {
                text += "=" + String(promotion.letter).uppercased()
            }
        } else {
            text = String(piece.kind.letter).uppercased() + disambiguation(for: move, piece: piece)
            if self[move.to] != nil {
                text += "x"
            }
            text += move.to.name
        }
        let next = played(move)
        if next.isInCheck {
            text += next.legalMoves().isEmpty ? "#" : "+"
        }
        return text
    }

    /// "", "b", "1" or "b1": what tells `move`'s piece from the others of its
    /// kind and colour that could legally go to the same square.
    private func disambiguation(for move: Move, piece: Piece) -> String {
        let rivals = Square.all.filter { square in
            square != move.from && self[square] == piece
                && legalMoves(from: square).contains { $0.to == move.to }
        }
        guard !rivals.isEmpty else { return "" }
        if !rivals.contains(where: { $0.file == move.from.file }) {
            return fileLetter(move.from)
        }
        if !rivals.contains(where: { $0.rank == move.from.rank }) {
            return String(move.from.rank + 1)
        }
        return move.from.name
    }

    private func fileLetter(_ square: Square) -> String {
        String(square.name.prefix(1))
    }
}

extension SANError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .illegalMove(let ply, let uci): "illegal move \(uci) at ply \(ply)"
        }
    }
}

/// Moves in SAN, replayed one after another from `start`.
///
/// Throws `SANError.illegalMove` at the first move that is not legal in the
/// position reached so far: SAN depends on the position, so nothing after it
/// could be written correctly. Callers that want what can be written use
/// `sanPrefix(of:from:)`.
public func sanMoves(_ moves: [Move], from start: Position = .starting) throws(SANError) -> [String] {
    let result = sanPrefix(of: moves, from: start)
    if result.count < moves.count {
        throw .illegalMove(ply: result.count + 1, uci: moves[result.count].uci)
    }
    return result
}

/// SAN for the legal start of `moves`: stops, without an error, at the first
/// move that is not legal. For showing as much of a game as possible.
public func sanPrefix(of moves: [Move], from start: Position = .starting) -> [String] {
    var position = start
    var result: [String] = []
    result.reserveCapacity(moves.count)
    for move in moves {
        guard let text = position.san(move) else { break }
        result.append(text)
        position = position.played(move)
    }
    return result
}
