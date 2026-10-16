import Testing

@testable import ChessCore

/// Reference node counts from https://www.chessprogramming.org/Perft_Results.
/// Each position stresses a different corner of the rules: castling through
/// attacked squares, en passant pins, promotions with capture, and so on.
struct PerftCase: Sendable, CustomTestStringConvertible {
    let name: String
    let fen: String
    let counts: [Int]  // counts[i] is perft(i + 1)

    var testDescription: String { name }
}

let perftCases: [PerftCase] = [
    PerftCase(name: "initial", fen: Position.startingFEN, counts: [20, 400, 8_902, 197_281]),
    PerftCase(
        name: "kiwipete", fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        counts: [48, 2_039, 97_862]),
    PerftCase(
        name: "position 3", fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        counts: [14, 191, 2_812, 43_238]),
    PerftCase(
        name: "position 4", fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        counts: [6, 264, 9_467]),
    PerftCase(
        name: "position 5", fen: "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        counts: [44, 1_486, 62_379]),
    PerftCase(
        name: "position 6", fen: "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        counts: [46, 2_079, 89_890]),
]

@Test(arguments: perftCases)
func perft(_ c: PerftCase) throws {
    let position = try Position(fen: c.fen)
    for (i, expected) in c.counts.enumerated() {
        #expect(position.perft(i + 1) == expected, "depth \(i + 1)")
    }
}
