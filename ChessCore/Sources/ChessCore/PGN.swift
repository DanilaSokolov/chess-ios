import Foundation

/// A game as Portable Game Notation (PGN) describes it: what goes into the
/// tags and the moves. Plain values, so ChessCore needs nothing from the
/// network layer; the app fills it from the game it read from history.
public struct PGNGame: Sendable, Hashable {
    /// How the game ended, as the result tag and the end of the movetext write it.
    public enum Result: String, Sendable, Hashable {
        case whiteWins = "1-0"
        case blackWins = "0-1"
        case draw = "1/2-1/2"
        /// Unfinished, or the result is not known.
        case unknown = "*"
    }

    public var event: String
    public var site: String
    /// When the game started. Written in UTC: `Date` and `UTCDate` as
    /// "YYYY.MM.DD", `UTCTime` as "HH:MM:SS". Nil writes "????.??.??".
    public var startedAt: Date?
    public var round: String
    public var white: String
    public var black: String
    public var result: Result
    /// Ratings before the game; only rated games have them.
    public var whiteElo: Int?
    public var blackElo: Int?
    /// "300+3": initial seconds + increment seconds. Nil leaves the tag out.
    public var timeControl: String?
    /// A PGN termination value: "normal", "time forfeit", "abandoned",
    /// "unterminated". Nil leaves the tag out.
    public var termination: String?
    /// From the starting position.
    public var moves: [Move]

    public init(
        event: String = "?", site: String = "?", startedAt: Date? = nil, round: String = "-",
        white: String, black: String, result: Result, whiteElo: Int? = nil, blackElo: Int? = nil,
        timeControl: String? = nil, termination: String? = nil, moves: [Move]
    ) {
        self.event = event
        self.site = site
        self.startedAt = startedAt
        self.round = round
        self.white = white
        self.black = black
        self.result = result
        self.whiteElo = whiteElo
        self.blackElo = blackElo
        self.timeControl = timeControl
        self.termination = termination
        self.moves = moves
    }
}

/// Writes PGN in export format: the Seven Tag Roster (Event, Site, Date,
/// Round, White, Black, Result) in that order, then UTCDate, UTCTime,
/// WhiteElo/BlackElo (rated games), TimeControl and Termination; an empty
/// line; the moves in SAN with move numbers, wrapped at `maxLineLength`, and
/// the result as the last token.
public enum PGNWriter {
    /// PGN's export format keeps lines to 80 characters at most.
    public static let maxLineLength = 80

    /// The whole game, ending with a newline.
    ///
    /// Throws `SANError.illegalMove` if a move is not legal where it is
    /// played: SAN cannot be written for it, nor for anything after it, and
    /// a PGN that stopped there silently would claim a different game.
    public static func write(_ game: PGNGame) throws(SANError) -> String {
        let san = try sanMoves(game.moves)
        return tags(of: game).map { "[\($0.name) \"\(escaped($0.value))\"]" }.joined(separator: "\n")
            + "\n\n" + movetext(san, result: game.result).joined(separator: "\n") + "\n"
    }

    /// Name and value of every tag, in the order they are written.
    static func tags(of game: PGNGame) -> [(name: String, value: String)] {
        var tags: [(name: String, value: String)] = [
            ("Event", game.event),
            ("Site", game.site),
            ("Date", game.startedAt.map { utc($0, "yyyy.MM.dd") } ?? "????.??.??"),
            ("Round", game.round),
            ("White", game.white),
            ("Black", game.black),
            ("Result", game.result.rawValue),
        ]
        if let start = game.startedAt {
            tags.append(("UTCDate", utc(start, "yyyy.MM.dd")))
            tags.append(("UTCTime", utc(start, "HH:mm:ss")))
        }
        if let elo = game.whiteElo { tags.append(("WhiteElo", String(elo))) }
        if let elo = game.blackElo { tags.append(("BlackElo", String(elo))) }
        if let timeControl = game.timeControl { tags.append(("TimeControl", timeControl)) }
        if let termination = game.termination { tags.append(("Termination", termination)) }
        return tags
    }

    /// A tag value between quotes: a backslash and a quote get a backslash
    /// in front; a line break, which a tag may not hold, becomes a space.
    public static func escaped(_ value: String) -> String {
        var out = ""
        for c in value {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r", "\r\n", "\t": out += " "
            default: out.append(c)
            }
        }
        return out
    }

    /// "1. e4 e5 2. Nf3 … 1-0" in lines of at most `maxLineLength`
    /// characters, broken only between tokens.
    public static func movetext(_ san: [String], result: PGNGame.Result) -> [String] {
        var tokens: [String] = []
        for (i, move) in san.enumerated() {
            if i.isMultiple(of: 2) {
                tokens.append("\(i / 2 + 1).")
            }
            tokens.append(move)
        }
        tokens.append(result.rawValue)
        var lines: [String] = []
        var line = ""
        for token in tokens {
            if line.isEmpty {
                line = token
            } else if line.count + 1 + token.count <= maxLineLength {
                line += " " + token
            } else {
                lines.append(line)
                line = token
            }
        }
        lines.append(line)
        return lines
    }

    private static func utc(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
