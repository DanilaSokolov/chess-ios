import ChessCore
import Testing

@testable import ChessClient

/// The position `fen`, the one after `uci`, and what the board must do between them.
private func changes(_ fen: String, _ uci: String) throws -> PieceChanges {
    let old = try Position(fen: fen)
    let move = try #require(Move(uci: uci))
    let new = try #require(old.applying(move), "\(uci) is not legal here")
    return PieceChanges(from: old, to: new, lastMove: move)
}

private func squares(_ names: String...) -> [Square] { names.map { Square($0)! } }

@Test func quietMoveSlidesOnePiece() throws {
    let c = try changes(Position.startingFEN, "e2e4")
    #expect(c.moved.map(\.from) == squares("e2") && c.moved.map(\.to) == squares("e4"))
    #expect(c.removed.isEmpty && c.added.isEmpty)
}

@Test func captureRemovesTheVictim() throws {
    let c = try changes("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", "e4d5")
    #expect(c.moved.map(\.from) == squares("e4") && c.moved.map(\.to) == squares("d5"))
    #expect(c.removed == squares("d5"))
    #expect(c.added.isEmpty)
}

@Test func castlingSlidesKingAndRook() throws {
    let c = try changes("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1g1")
    #expect(Set(c.moved.map { "\($0.from)\($0.to)" }) == ["e1g1", "h1f1"])
    #expect(c.removed.isEmpty && c.added.isEmpty)
}

@Test func enPassantRemovesThePawnBesideIt() throws {
    let c = try changes("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6")
    #expect(c.moved.map(\.from) == squares("e5") && c.moved.map(\.to) == squares("d6"))
    #expect(c.removed == squares("d5"), "the captured pawn is not on the target square")
}

@Test func promotionReplacesThePawn() throws {
    let c = try changes("4k3/P7/8/8/8/8/8/4K3 w - - 0 1", "a7a8q")
    #expect(c.moved.isEmpty)
    #expect(c.removed == squares("a7"))
    #expect(c.added == squares("a8"))
}

/// Two knights could reach f3; the one that moved is the one that slides.
@Test func theMovedPieceIsTheOneThatSlides() throws {
    let c = try changes("4k3/8/8/8/8/8/8/1N2K1N1 w - - 0 1", "g1f3")
    #expect(c.moved.map(\.from) == squares("g1"))
}

@Test func samePositionChangesNothing() {
    #expect(PieceChanges(from: .starting, to: .starting).isEmpty)
}

/// A snapshot after a reconnect can jump several moves; matching still keeps
/// every piece that is the same kind, so only what truly changed is rebuilt.
@Test func severalMovesAtOnceStillMatchPieces() throws {
    let new = try Position(fen: "rnbqkb1r/pppp1ppp/5n2/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3")
    let c = PieceChanges(from: .starting, to: new)
    #expect(c.moved.count == 4)  // e2e4, e7e5, g1f3, g8f6
    #expect(c.removed.isEmpty && c.added.isEmpty)
}
