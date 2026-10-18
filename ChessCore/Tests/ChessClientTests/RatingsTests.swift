import ChessCore
import ChessNet
import Foundation
import Testing

@testable import ChessClient

/// The same thresholds as the server: initial + 40 × increment seconds,
/// under 180 bullet, under 480 blitz, under 1500 rapid, else classical.
private let categoryCases: [(TimeControl, RatingCategory)] = [
    (TimeControl(minutes: 1, increment: 0), .bullet),
    (TimeControl(minutes: 2, increment: 1), .bullet),  // 160 s
    (TimeControl(initialSeconds: 179, incrementSeconds: 0), .bullet),
    (TimeControl(initialSeconds: 180, incrementSeconds: 0), .blitz),
    (TimeControl(minutes: 3, increment: 2), .blitz),  // 260 s
    (TimeControl(minutes: 5, increment: 0), .blitz),
    (TimeControl(initialSeconds: 479, incrementSeconds: 0), .blitz),
    (TimeControl(initialSeconds: 0, incrementSeconds: 12), .rapid),  // 480 s
    (TimeControl(minutes: 10, increment: 0), .rapid),
    (TimeControl(minutes: 15, increment: 10), .rapid),  // 1300 s
    (TimeControl(initialSeconds: 1499, incrementSeconds: 0), .rapid),
    (TimeControl(minutes: 25, increment: 0), .classical),  // 1500 s
    (TimeControl(minutes: 30, increment: 20), .classical),
]

@Test(arguments: categoryCases)
func ratingCategory(_ timeControl: TimeControl, _ expected: RatingCategory) {
    #expect(timeControl.ratingCategory == expected, "\(timeControl) is \(timeControl.estimatedSeconds) s")
}

@Test func lobbyCategoriesAreEachShownOnceFastestFirst() {
    #expect(RatingCategory.categories(of: TimeControl.presets) == [.bullet, .blitz, .rapid])
    #expect(RatingCategory.categories(of: []) == [])
}

@Test func ratingTexts() {
    let settled = Rating(
        category: .blitz, rating: 1519.5, deviation: 60, volatility: 0.06, games: 40, isProvisional: false)
    #expect(ratingText(settled) == "1520")
    var unsure = settled
    unsure.isProvisional = true
    #expect(ratingText(unsure) == "1520?")
    #expect(ratingText(nil) == "1500?")
    #expect(ratingChangeText(12) == "+12")
    #expect(ratingChangeText(-8) == "\u{2212}8")
    #expect(ratingChangeText(0) == "\u{00B1}0")
}

// MARK: - PGN of a game from history

private func game(rated: Bool) -> HistoryGame {
    HistoryGame(
        id: "g1", whiteName: "alice", blackName: "Bob \"the\" Bot", yourColor: .white, result: .blackWins,
        termination: .timeout, timeControl: TimeControl(minutes: 5, increment: 3),
        moves: ["e2e4", "e7e5", "g1f3"].compactMap(Move.init(uci:)),
        startedAt: Date(timeIntervalSince1970: 1_792_155_600),  // 2026-10-16 13:00 UTC
        finishedAt: Date(timeIntervalSince1970: 1_792_156_000),
        isRated: rated, whiteRatingBefore: rated ? 1520 : nil, blackRatingBefore: rated ? 1487 : nil,
        ratingChange: rated ? -8 : nil)
}

@Test func pgnOfARatedGame() throws {
    let pgn = try game(rated: true).pgn(site: "chess.example")
    #expect(pgn.hasPrefix("[Event \"Rated Blitz game\"]\n[Site \"chess.example\"]\n[Date \"2026.10.16\"]\n"))
    #expect(pgn.contains("[Black \"Bob \\\"the\\\" Bot\"]"))
    #expect(pgn.contains("[WhiteElo \"1520\"]\n[BlackElo \"1487\"]\n"))
    #expect(pgn.contains("[TimeControl \"300+3\"]\n[Termination \"time forfeit\"]\n"))
    #expect(pgn.hasSuffix("\n\n1. e4 e5 2. Nf3 0-1\n"))
}

@Test func pgnOfAnUnratedGameHasNoElo() throws {
    let pgn = try game(rated: false).pgn()
    #expect(pgn.hasPrefix("[Event \"Casual game\"]\n[Site \"?\"]\n"))
    #expect(!pgn.contains("Elo"))
}

@Test func pgnFileName() {
    #expect(game(rated: false).pgnFileName == "alice-Bob__the__Bot-2026-10-16.pgn")
    var odd = game(rated: false)
    odd.whiteName = "../"
    odd.blackName = "Иван"
    #expect(odd.pgnFileName == "Player-Иван-2026-10-16.pgn")
}
