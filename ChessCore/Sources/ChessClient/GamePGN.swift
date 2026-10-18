import ChessCore
import ChessNet
import Foundation

extension HistoryGame {
    /// The game as a PGN file's text, for sharing or copying. `site` is where
    /// it was played, e.g. the server's host name.
    ///
    /// Throws `SANError.illegalMove` if a move does not apply where it was
    /// played (the server's rules and ours disagree): the moves could not be
    /// written correctly, so there is nothing to export.
    public func pgn(site: String = "?") throws(SANError) -> String {
        try PGNWriter.write(pgnGame(site: site))
    }

    /// What goes into the PGN.
    public func pgnGame(site: String = "?") -> PGNGame {
        PGNGame(
            event: isRated ? "Rated \(timeControl.ratingCategory.pgnName) game" : "Casual game",
            site: site, startedAt: startedAt, white: whiteName, black: blackName, result: pgnResult,
            whiteElo: isRated ? whiteRatingBefore : nil, blackElo: isRated ? blackRatingBefore : nil,
            timeControl: "\(timeControl.initialSeconds)+\(timeControl.incrementSeconds)",
            termination: termination.pgnValue, moves: moves)
    }

    /// "White-Black-2026-10-16.pgn": the players and the day the game
    /// started (UTC, as in the PGN). Characters a file name should not hold
    /// become "_".
    public var pgnFileName: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.dateComponents([.year, .month, .day], from: startedAt)
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return "\(Self.fileNamePart(whiteName))-\(Self.fileNamePart(blackName))-\(date).pgn"
    }

    private static func fileNamePart(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." ? $0 : "_" })
        let part = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return part.isEmpty ? "Player" : String(part.prefix(40))
    }

    private var pgnResult: PGNGame.Result {
        switch result {
        case .whiteWins: .whiteWins
        case .blackWins: .blackWins
        case .draw: .draw
        case .unknown: .unknown
        }
    }
}

extension RatingCategory {
    /// The English name PGN tools expect in the Event tag ("Rated Blitz game").
    var pgnName: String {
        switch self {
        case .bullet: "Bullet"
        case .blitz: "Blitz"
        case .rapid: "Rapid"
        case .classical: "Classical"
        }
    }
}

extension Termination {
    /// The PGN Termination tag (PGN standard, 9.8.1): how the game ended in
    /// general terms. The exact reason (checkmate, resignation…) is in the
    /// moves and the result.
    var pgnValue: String {
        switch self {
        case .checkmate, .stalemate, .insufficientMaterial, .threefoldRepetition, .fiftyMoveRule, .resignation,
            .drawAgreement:
            "normal"
        case .timeout: "time forfeit"
        case .abandonment: "abandoned"
        case .unknown: "unterminated"
        }
    }
}
