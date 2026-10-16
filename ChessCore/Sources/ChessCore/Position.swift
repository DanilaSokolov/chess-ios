/// A complete chess position: piece placement plus the state FEN records
/// (side to move, castling rights, en passant square and move counters).
///
/// Position is a value type; making a move returns a new position.
public struct Position: Sendable, Hashable {
    /// Indexed by `Square.index`.
    public internal(set) var board: [Piece?]
    public internal(set) var sideToMove: PieceColor
    public internal(set) var castling: CastlingRights
    /// The square a pawn skipped over on the previous move, if any.
    public internal(set) var enPassant: Square?
    public internal(set) var halfmoveClock: Int
    public internal(set) var fullmoveNumber: Int

    public static let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    public static let starting = try! Position(fen: startingFEN)

    public subscript(square: Square) -> Piece? { board[square.index] }

    public var isInCheck: Bool {
        guard let king = kingSquare(of: sideToMove) else { return false }
        return isAttacked(king, by: sideToMove.opponent)
    }

    public var status: GameStatus {
        guard legalMoves().isEmpty else { return .ongoing }
        return isInCheck ? .checkmate(winner: sideToMove.opponent) : .stalemate
    }

    public func kingSquare(of color: PieceColor) -> Square? {
        let king = Piece(color, .king)
        return board.firstIndex(of: king).flatMap { Square(index: $0) }
    }

    /// Returns the position after `move`, or nil if the move is illegal here.
    public func applying(_ move: Move) -> Position? {
        guard isLegal(move) else { return nil }
        return played(move)
    }

    public func isLegal(_ move: Move) -> Bool {
        legalMoves(from: move.from).contains(move)
    }
}

// MARK: - Making moves

extension Position {
    /// Plays a move that is known to be pseudo-legal. Does not check whether it
    /// leaves the mover's king in check.
    func played(_ move: Move) -> Position {
        var next = self
        guard let piece = board[move.from.index] else { return next }
        let color = piece.color
        var isCapture = board[move.to.index] != nil

        next.board[move.from.index] = nil

        if piece.kind == .pawn, move.to == enPassant, !isCapture {
            // The captured pawn stands beside the moving pawn, not on `to`.
            next.board[move.to.file + move.from.rank * 8] = nil
            isCapture = true
        }

        if piece.kind == .king, abs(move.to.file - move.from.file) == 2 {
            let kingside = move.to.file > move.from.file
            let rookFrom = Square(file: kingside ? 7 : 0, rank: move.from.rank)!
            let rookTo = Square(file: kingside ? 5 : 3, rank: move.from.rank)!
            next.board[rookTo.index] = next.board[rookFrom.index]
            next.board[rookFrom.index] = nil
        }

        next.board[move.to.index] = move.promotion.map { Piece(color, $0) } ?? piece

        if piece.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 {
            next.enPassant = Square(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
        } else {
            next.enPassant = nil
        }

        if piece.kind == .king {
            next.castling.subtract([.kingside(color), .queenside(color)])
        }
        // A rook leaving or being captured on its home square loses that right.
        for square in [move.from, move.to] {
            switch square.index {
            case 0: next.castling.remove(.whiteQueenside)
            case 7: next.castling.remove(.whiteKingside)
            case 56: next.castling.remove(.blackQueenside)
            case 63: next.castling.remove(.blackKingside)
            default: break
            }
        }

        next.halfmoveClock = (piece.kind == .pawn || isCapture) ? 0 : halfmoveClock + 1
        if color == .black {
            next.fullmoveNumber += 1
        }
        next.sideToMove = color.opponent
        return next
    }
}

// MARK: - Move generation

extension Position {
    private static let knightSteps = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingSteps = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let rookRays = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let bishopRays = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    /// All legal moves for the side to move.
    public func legalMoves() -> [Move] {
        Square.all.flatMap { legalMoves(from: $0) }
    }

    /// Legal moves of the piece on `square`; empty if it is not the side to move.
    public func legalMoves(from square: Square) -> [Move] {
        guard let piece = self[square], piece.color == sideToMove else { return [] }
        return pseudoLegalMoves(from: square, piece: piece).filter { move in
            let next = played(move)
            guard let king = next.kingSquare(of: piece.color) else { return true }
            return !next.isAttacked(king, by: piece.color.opponent)
        }
    }

    /// Moves that obey how pieces move but may leave the king in check.
    private func pseudoLegalMoves(from square: Square, piece: Piece) -> [Move] {
        var moves: [Move] = []
        switch piece.kind {
        case .pawn:
            addPawnMoves(from: square, color: piece.color, to: &moves)
        case .knight:
            addSteps(Self.knightSteps, from: square, color: piece.color, to: &moves)
        case .bishop:
            addRays(Self.bishopRays, from: square, color: piece.color, to: &moves)
        case .rook:
            addRays(Self.rookRays, from: square, color: piece.color, to: &moves)
        case .queen:
            addRays(Self.rookRays + Self.bishopRays, from: square, color: piece.color, to: &moves)
        case .king:
            addSteps(Self.kingSteps, from: square, color: piece.color, to: &moves)
            addCastling(from: square, color: piece.color, to: &moves)
        }
        return moves
    }

    private func addPawnMoves(from square: Square, color: PieceColor, to moves: inout [Move]) {
        let dir = color == .white ? 1 : -1
        let startRank = color == .white ? 1 : 6
        let lastRank = color == .white ? 7 : 0

        func add(_ to: Square) {
            if to.rank == lastRank {
                for kind in PieceKind.promotions {
                    moves.append(Move(from: square, to: to, promotion: kind))
                }
            } else {
                moves.append(Move(from: square, to: to))
            }
        }

        if let one = square.offset(0, dir), self[one] == nil {
            add(one)
            if square.rank == startRank, let two = square.offset(0, 2 * dir), self[two] == nil {
                add(two)
            }
        }
        for df in [-1, 1] {
            guard let target = square.offset(df, dir) else { continue }
            if let victim = self[target], victim.color != color {
                add(target)
            } else if target == enPassant {
                add(target)
            }
        }
    }

    private func addSteps(_ steps: [(Int, Int)], from square: Square, color: PieceColor, to moves: inout [Move]) {
        for (df, dr) in steps {
            guard let target = square.offset(df, dr) else { continue }
            if self[target]?.color != color {
                moves.append(Move(from: square, to: target))
            }
        }
    }

    private func addRays(_ rays: [(Int, Int)], from square: Square, color: PieceColor, to moves: inout [Move]) {
        for (df, dr) in rays {
            var current = square
            while let target = current.offset(df, dr) {
                if let blocker = self[target] {
                    if blocker.color != color {
                        moves.append(Move(from: square, to: target))
                    }
                    break
                }
                moves.append(Move(from: square, to: target))
                current = target
            }
        }
    }

    private func addCastling(from square: Square, color: PieceColor, to moves: inout [Move]) {
        let rank = color == .white ? 0 : 7
        guard square == Square(file: 4, rank: rank) else { return }
        let enemy = color.opponent
        let rook = Piece(color, .rook)

        func empty(_ files: [Int]) -> Bool { files.allSatisfy { self[Square(file: $0, rank: rank)!] == nil } }
        func safe(_ files: [Int]) -> Bool { files.allSatisfy { !isAttacked(Square(file: $0, rank: rank)!, by: enemy) } }

        // The king may not castle out of, through, or into check.
        if castling.contains(.kingside(color)), self[Square(file: 7, rank: rank)!] == rook,
            empty([5, 6]), safe([4, 5, 6])
        {
            moves.append(Move(from: square, to: Square(file: 6, rank: rank)!))
        }
        if castling.contains(.queenside(color)), self[Square(file: 0, rank: rank)!] == rook,
            empty([1, 2, 3]), safe([4, 3, 2])
        {
            moves.append(Move(from: square, to: Square(file: 2, rank: rank)!))
        }
    }

    /// Whether any piece of `color` attacks `square`.
    public func isAttacked(_ square: Square, by color: PieceColor) -> Bool {
        // Pawns of `color` attack diagonally forward, so look backwards from the target.
        let pawnDir = color == .white ? -1 : 1
        for df in [-1, 1] {
            if let from = square.offset(df, pawnDir), self[from] == Piece(color, .pawn) {
                return true
            }
        }
        for (df, dr) in Self.knightSteps {
            if let from = square.offset(df, dr), self[from] == Piece(color, .knight) {
                return true
            }
        }
        for (df, dr) in Self.kingSteps {
            if let from = square.offset(df, dr), self[from] == Piece(color, .king) {
                return true
            }
        }
        func rayHits(_ rays: [(Int, Int)], _ kinds: Set<PieceKind>) -> Bool {
            for (df, dr) in rays {
                var current = square
                while let next = current.offset(df, dr) {
                    if let piece = self[next] {
                        if piece.color == color, kinds.contains(piece.kind) {
                            return true
                        }
                        break
                    }
                    current = next
                }
            }
            return false
        }
        return rayHits(Self.rookRays, [.rook, .queen]) || rayHits(Self.bishopRays, [.bishop, .queen])
    }

    /// Counts leaf nodes of the legal move tree to `depth`. Used to verify move
    /// generation against published reference numbers.
    public func perft(_ depth: Int) -> Int {
        guard depth > 0 else { return 1 }
        let moves = legalMoves()
        if depth == 1 { return moves.count }
        return moves.reduce(0) { $0 + played($1).perft(depth - 1) }
    }
}
