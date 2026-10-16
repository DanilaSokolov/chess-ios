import Testing

@testable import ChessCore

@Test(arguments: [
    Position.startingFEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
    "8/8/8/8/8/8/8/K6k b - - 99 120",
])
func fenRoundTrip(_ fen: String) throws {
    #expect(try Position(fen: fen).fen == fen)
}

@Test(arguments: [
    "",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1",
    "rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KX - 0 1",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e4 0 1",
])
func fenRejectsGarbage(_ fen: String) {
    #expect(throws: FENError.self) { try Position(fen: fen) }
}

@Test func uciParsing() {
    #expect(Move(uci: "e2e4") == Move(from: Square("e2")!, to: Square("e4")!))
    #expect(Move(uci: "e7e8q")?.promotion == .queen)
    #expect(Move(uci: "e7e8k") == nil)
    #expect(Move(uci: "e2e9") == nil)
    #expect(Move(uci: "e2") == nil)
    #expect(Move(uci: "a7a8n")?.uci == "a7a8n")
}

@Test func foolsMateIsCheckmate() throws {
    var p = Position.starting
    for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] {
        p = try #require(p.applying(Move(uci: uci)!), "\(uci) should be legal")
    }
    #expect(p.isInCheck)
    #expect(p.status == .checkmate(winner: .black))
}

@Test func stalemate() throws {
    let p = try Position(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
    #expect(!p.isInCheck)
    #expect(p.status == .stalemate)
}

@Test func illegalMovesAreRefused() {
    let p = Position.starting
    #expect(p.applying(Move(uci: "e2e5")!) == nil)  // Pawn too far.
    #expect(p.applying(Move(uci: "e7e5")!) == nil)  // Not Black's turn.
    #expect(p.applying(Move(uci: "e1g1")!) == nil)  // Castling through pieces.
}

@Test func castlingMovesTheRookAndClearsRights() throws {
    let p = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    let castled = try #require(p.applying(Move(uci: "e1g1")!))
    #expect(castled[Square("g1")!] == Piece(.white, .king))
    #expect(castled[Square("f1")!] == Piece(.white, .rook))
    #expect(castled[Square("h1")!] == nil)
    #expect(castled.castling == [.blackKingside, .blackQueenside])
}

@Test func enPassantRemovesTheCapturedPawn() throws {
    let p = try Position(fen: "rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3")
    let next = try #require(p.applying(Move(uci: "e5f6")!))
    #expect(next[Square("f6")!] == Piece(.white, .pawn))
    #expect(next[Square("f5")!] == nil)
    #expect(next.fen == "rnbqkbnr/ppp1p1pp/5P2/3p4/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 3")
}

@Test func promotionOffersFourPieces() throws {
    let p = try Position(fen: "8/P7/8/8/8/8/8/k6K w - - 0 1")
    let promotions = p.legalMoves(from: Square("a7")!)
    #expect(Set(promotions.compactMap(\.promotion)) == Set(PieceKind.promotions))
    let queened = try #require(p.applying(Move(uci: "a7a8q")!))
    #expect(queened[Square("a8")!] == Piece(.white, .queen))
}
