public enum PieceColor: Sendable, Hashable {
    case white, black

    public var opponent: PieceColor { self == .white ? .black : .white }
}

public enum PieceKind: Sendable, Hashable, CaseIterable {
    case pawn, knight, bishop, rook, queen, king

    /// Pieces a pawn may promote to, most useful first.
    public static let promotions: [PieceKind] = [.queen, .rook, .bishop, .knight]

    /// Lowercase letter used by FEN and UCI.
    public var letter: Character {
        switch self {
        case .pawn: "p"
        case .knight: "n"
        case .bishop: "b"
        case .rook: "r"
        case .queen: "q"
        case .king: "k"
        }
    }

    public init?(letter: Character) {
        guard let kind = PieceKind.allCases.first(where: { $0.letter == Character(letter.lowercased()) }) else {
            return nil
        }
        self = kind
    }
}

public struct Piece: Sendable, Hashable {
    public let color: PieceColor
    public let kind: PieceKind

    public init(_ color: PieceColor, _ kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    /// FEN letter: uppercase for White, lowercase for Black.
    public var fenCharacter: Character {
        color == .white ? Character(kind.letter.uppercased()) : kind.letter
    }

    public init?(fenCharacter c: Character) {
        guard let kind = PieceKind(letter: c) else { return nil }
        self.init(c.isUppercase ? .white : .black, kind)
    }
}

/// A board square. Index 0 is a1, 7 is h1, 63 is h8.
public struct Square: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let index: Int

    public init?(index: Int) {
        guard (0..<64).contains(index) else { return nil }
        self.index = index
    }

    /// File and rank are 0-based: file 0 is "a", rank 0 is "1".
    public init?(file: Int, rank: Int) {
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        index = rank * 8 + file
    }

    /// Parses algebraic names such as "e4".
    public init?(_ name: some StringProtocol) {
        let chars = Array(name)
        guard chars.count == 2,
            let f = chars[0].asciiValue, let r = chars[1].asciiValue,
            (97...104).contains(f), (49...56).contains(r)
        else { return nil }
        self.init(file: Int(f - 97), rank: Int(r - 49))
    }

    public var file: Int { index & 7 }
    public var rank: Int { index >> 3 }

    public var name: String {
        String(UnicodeScalar(UInt8(97 + file))) + String(rank + 1)
    }

    public var description: String { name }

    /// The square `df` files and `dr` ranks away, or nil when off the board.
    public func offset(_ df: Int, _ dr: Int) -> Square? {
        Square(file: file + df, rank: rank + dr)
    }

    public static func < (a: Square, b: Square) -> Bool { a.index < b.index }

    public static let all: [Square] = (0..<64).map { Square(index: $0)! }
}

public struct Move: Sendable, Hashable, CustomStringConvertible {
    public let from: Square
    public let to: Square
    public let promotion: PieceKind?

    public init(from: Square, to: Square, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// Parses long algebraic UCI notation: "e2e4", "e7e8q". Castling is the
    /// king's two-square move, "e1g1".
    public init?(uci: String) {
        guard uci.count == 4 || uci.count == 5,
            let from = Square(uci.prefix(2)),
            let to = Square(uci.dropFirst(2).prefix(2))
        else { return nil }
        var promotion: PieceKind?
        if uci.count == 5 {
            guard let kind = PieceKind(letter: uci.last!), PieceKind.promotions.contains(kind) else { return nil }
            promotion = kind
        }
        self.init(from: from, to: to, promotion: promotion)
    }

    public var uci: String {
        from.name + to.name + (promotion.map { String($0.letter) } ?? "")
    }

    public var description: String { uci }
}

public struct CastlingRights: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let whiteKingside = CastlingRights(rawValue: 1 << 0)
    public static let whiteQueenside = CastlingRights(rawValue: 1 << 1)
    public static let blackKingside = CastlingRights(rawValue: 1 << 2)
    public static let blackQueenside = CastlingRights(rawValue: 1 << 3)

    public static let all: CastlingRights = [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]

    static func kingside(_ c: PieceColor) -> CastlingRights { c == .white ? .whiteKingside : .blackKingside }
    static func queenside(_ c: PieceColor) -> CastlingRights { c == .white ? .whiteQueenside : .blackQueenside }
}

public enum GameStatus: Sendable, Hashable {
    case ongoing
    case checkmate(winner: PieceColor)
    case stalemate
}
