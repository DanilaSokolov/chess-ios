public enum FENError: Error, Sendable, Equatable {
    case wrongFieldCount
    case badPlacement
    case badSideToMove
    case badCastling
    case badEnPassant
    case badCounter
}

extension Position {
    /// Parses Forsyth–Edwards Notation. The two move counters may be omitted.
    public init(fen: String) throws(FENError) {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 4 || fields.count == 6 else { throw .wrongFieldCount }

        var board = [Piece?](repeating: nil, count: 64)
        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { throw .badPlacement }
        for (i, row) in ranks.enumerated() {
            let rank = 7 - i
            var file = 0
            for c in row {
                if let skip = c.wholeNumberValue, (1...8).contains(skip) {
                    file += skip
                } else if let piece = Piece(fenCharacter: c), file < 8 {
                    board[rank * 8 + file] = piece
                    file += 1
                } else {
                    throw .badPlacement
                }
            }
            guard file == 8 else { throw .badPlacement }
        }

        let side: PieceColor
        switch fields[1] {
        case "w": side = .white
        case "b": side = .black
        default: throw .badSideToMove
        }

        var castling: CastlingRights = []
        if fields[2] != "-" {
            for c in fields[2] {
                switch c {
                case "K": castling.insert(.whiteKingside)
                case "Q": castling.insert(.whiteQueenside)
                case "k": castling.insert(.blackKingside)
                case "q": castling.insert(.blackQueenside)
                default: throw .badCastling
                }
            }
        }

        var enPassant: Square?
        if fields[3] != "-" {
            guard let square = Square(fields[3]), square.rank == 2 || square.rank == 5 else { throw .badEnPassant }
            enPassant = square
        }

        var halfmove = 0
        var fullmove = 1
        if fields.count == 6 {
            guard let h = Int(fields[4]), h >= 0, let f = Int(fields[5]), f >= 1 else { throw .badCounter }
            halfmove = h
            fullmove = f
        }

        self.board = board
        self.sideToMove = side
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmove
        self.fullmoveNumber = fullmove
    }

    public var fen: String {
        var rows: [String] = []
        for rank in (0..<8).reversed() {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let piece = board[rank * 8 + file] {
                    if empty > 0 { row += String(empty) }
                    empty = 0
                    row.append(piece.fenCharacter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }

        var rights = ""
        if castling.contains(.whiteKingside) { rights += "K" }
        if castling.contains(.whiteQueenside) { rights += "Q" }
        if castling.contains(.blackKingside) { rights += "k" }
        if castling.contains(.blackQueenside) { rights += "q" }

        return [
            rows.joined(separator: "/"),
            sideToMove == .white ? "w" : "b",
            rights.isEmpty ? "-" : rights,
            enPassant?.name ?? "-",
            String(halfmoveClock),
            String(fullmoveNumber),
        ].joined(separator: " ")
    }
}
