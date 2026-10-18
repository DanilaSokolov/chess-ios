import Foundation
import Testing

@testable import ChessCore

private func moves(_ uci: String) -> [Move] {
    uci.split(separator: " ").map { Move(uci: String($0))! }
}

private func san(_ fen: String, _ uci: String) throws -> String? {
    try Position(fen: fen).san(Move(uci: uci)!)
}

/// Morphy against the Duke of Brunswick and Count Isouard, Paris 1858.
private let operaUCI =
    "e2e4 e7e5 g1f3 d7d6 d2d4 c8g4 d4e5 g4f3 d1f3 d6e5 f1c4 g8f6 f3b3 d8e7 b1c3 c7c6 c1g5 b7b5 c3b5 c6b5 "
    + "c4b5 b8d7 e1c1 a8d8 d1d7 d8d7 h1d1 e7e6 b5d7 f6d7 b3b8 d7b8 d1d8"
private let operaSAN =
    "e4 e5 Nf3 d6 d4 Bg4 dxe5 Bxf3 Qxf3 dxe5 Bc4 Nf6 Qb3 Qe7 Nc3 c6 Bg5 b5 Nxb5 cxb5 "
    + "Bxb5+ Nbd7 O-O-O Rd8 Rxd7 Rxd7 Rd1 Qe6 Bxd7+ Nxd7 Qb8+ Nxb8 Rd8#"

@Test func operaGame() throws {
    #expect(try sanMoves(moves(operaUCI)) == operaSAN.split(separator: " ").map(String.init))
}

@Test func pawnCapturesNameTheFile() throws {
    #expect(try sanMoves(moves("e2e4 d7d5 e4d5")) == ["e4", "d5", "exd5"])
}

@Test func enPassant() throws {
    #expect(try san("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3", "e5f6") == "exf6")
}

@Test func knightsOnDifferentFilesAreToldApartByFile() throws {
    let fen = "4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1"
    #expect(try san(fen, "b1d2") == "Nbd2")
    #expect(try san(fen, "f3d2") == "Nfd2")
    #expect(try san(fen, "f3g5") == "Ng5", "only one knight reaches g5")
}

@Test func rooksOnOneFileAreToldApartByRank() throws {
    let fen = "4k3/8/8/R7/8/8/8/R3K3 w - - 0 1"
    #expect(try san(fen, "a1a3") == "R1a3")
    #expect(try san(fen, "a5a3") == "R5a3")
    #expect(try san(fen, "a1b1") == "Rb1")
}

@Test func threeQueensNeedTheWholeSquare() throws {
    // Queens on a1, a3 and c1 all reach b2: a3 shares a1's file, c1 its rank.
    let fen = "4k3/8/8/8/8/Q7/8/Q1Q4K w - - 0 1"
    #expect(try san(fen, "a1b2") == "Qa1b2")
}

@Test func pinnedPieceNeedsNoDisambiguation() throws {
    // Knights on b5 and e2 both reach d4, but the one on e2 is pinned to the
    // king by the rook on e8: only one knight may go there, so no "Nbd4".
    let fen = "4r1k1/8/8/1N6/8/8/4N3/4K3 w - - 0 1"
    #expect(try san(fen, "b5d4") == "Nd4")
}

@Test func promotion() throws {
    let fen = "r3k3/1P6/8/8/8/8/8/4K3 w - - 0 1"
    #expect(try san(fen, "b7b8q") == "b8=Q+")
    #expect(try san(fen, "b7b8n") == "b8=N")
    #expect(try san(fen, "b7a8q") == "bxa8=Q+")
    #expect(try san(fen, "b7b8") == nil, "a pawn on the last rank must promote")
}

@Test func castling() throws {
    let fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
    #expect(try san(fen, "e1g1") == "O-O")
    #expect(try san(fen, "e1c1") == "O-O-O")
    let black = "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1"
    #expect(try san(black, "e8g8") == "O-O")
    #expect(try san(black, "e8c8") == "O-O-O")
    #expect(try san("5k2/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1") == "O-O+", "the rook gives check from f1")
}

@Test func checkAndMate() throws {
    #expect(try sanMoves(moves("f2f3 e7e5 g2g4 d8h4")) == ["f3", "e5", "g4", "Qh4#"])
    #expect(try san("4k3/8/8/8/8/8/8/R3K3 w - - 0 1", "a1a8") == "Ra8+")
}

@Test func illegalMoveStopsTheGame() throws {
    #expect(throws: SANError.illegalMove(ply: 3, uci: "e4e5")) {
        try sanMoves(moves("e2e4 e7e5 e4e5 g8f6"))
    }
    #expect(sanPrefix(of: moves("e2e4 e7e5 e4e5 g8f6")) == ["e4", "e5"], "what comes before is kept")
    #expect(Position.starting.san(Move(uci: "e7e5")!) == nil, "not Black's turn")
}

// MARK: - PGN

private let operaPGN = PGNGame(
    // 2026-10-15 13:00 UTC.
    event: "Casual game", site: "Paris", startedAt: Date(timeIntervalSince1970: 1_792_069_200),
    white: "Paul Morphy", black: "Duke Karl / Count Isouard", result: .whiteWins,
    timeControl: "300+3", termination: "normal", moves: moves(operaUCI))

@Test func pgnHeaders() throws {
    let pgn = try PGNWriter.write(operaPGN)
    let header = pgn.components(separatedBy: "\n\n")[0].split(separator: "\n").map(String.init)
    #expect(
        header == [
            "[Event \"Casual game\"]",
            "[Site \"Paris\"]",
            "[Date \"2026.10.15\"]",
            "[Round \"-\"]",
            "[White \"Paul Morphy\"]",
            "[Black \"Duke Karl / Count Isouard\"]",
            "[Result \"1-0\"]",
            "[UTCDate \"2026.10.15\"]",
            "[UTCTime \"13:00:00\"]",
            "[TimeControl \"300+3\"]",
            "[Termination \"normal\"]",
        ])
    #expect(!pgn.contains("Elo"), "an unrated game has no ratings")
}

@Test func pgnRatingsForRatedGames() throws {
    var game = operaPGN
    game.whiteElo = 1520
    game.blackElo = 1487
    let pgn = try PGNWriter.write(game)
    #expect(
        pgn.contains(
            "[UTCTime \"13:00:00\"]\n[WhiteElo \"1520\"]\n[BlackElo \"1487\"]\n[TimeControl \"300+3\"]\n"),
        "after the dates, before the time control")
}

@Test func pgnMovetextIsNumberedWrappedAndEndsWithTheResult() throws {
    let pgn = try PGNWriter.write(operaPGN)
    #expect(pgn.hasSuffix(" Rd8# 1-0\n"))
    let movetext = pgn.components(separatedBy: "\n\n")[1].split(separator: "\n").map(String.init)
    #expect(movetext.count > 1, "too long for one line")
    #expect(movetext.allSatisfy { $0.count <= PGNWriter.maxLineLength })
    #expect(movetext.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
    #expect(
        movetext.joined(separator: " ")
            == "1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 "
            + "8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 "
            + "14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0")
    // Greedy: a line ends only when the next token would not fit.
    for (line, next) in zip(movetext, movetext.dropFirst()) {
        let firstToken = next.split(separator: " ")[0]
        #expect(line.count + 1 + firstToken.count > PGNWriter.maxLineLength)
    }
}

@Test func pgnResults() throws {
    let cases: [(PGNGame.Result, String)] = [(.blackWins, "0-1"), (.draw, "1/2-1/2"), (.unknown, "*")]
    for (result, text) in cases {
        let pgn = try PGNWriter.write(PGNGame(white: "a", black: "b", result: result, moves: []))
        #expect(pgn.contains("[Result \"\(text)\"]"))
        #expect(pgn.hasSuffix("\n\n\(text)\n"), "no moves: the movetext is the result alone")
        #expect(pgn.contains("[Date \"????.??.??\"]"))
        #expect(!pgn.contains("UTCDate"))
    }
}

@Test func pgnEscapesTagValues() throws {
    #expect(PGNWriter.escaped(#"Bob "the \ Bot""#) == #"Bob \"the \\ Bot\""#)
    #expect(PGNWriter.escaped("two\nlines") == "two lines")
    let pgn = try PGNWriter.write(PGNGame(white: #"A "B""#, black: #"C\D"#, result: .draw, moves: []))
    #expect(pgn.contains(#"[White "A \"B\""]"#))
    #expect(pgn.contains(#"[Black "C\\D"]"#))
}

@Test func pgnRefusesAnIllegalMove() {
    let game = PGNGame(white: "a", black: "b", result: .unknown, moves: moves("e2e4 e2e4"))
    #expect(throws: SANError.illegalMove(ply: 2, uci: "e2e4")) { try PGNWriter.write(game) }
}
