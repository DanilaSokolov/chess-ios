import ChessCore
import ChessProto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
internal import SwiftProtobuf

/// How a finished game ended for the player looking at it.
public enum Outcome: Sendable, Hashable {
    case win, loss, draw, unknown
}

/// A game in the player's history list.
public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var yourColor: PieceColor
    public var opponentName: String
    /// The opponent is a guest (a bot): no account.
    public var opponentIsGuest: Bool
    public var outcome: Outcome
    public var termination: Termination
    public var timeControl: TimeControl
    /// Half-moves played.
    public var plies: Int
    public var finishedAt: Date
    /// The ratings this game changed, nil for an unrated game (only games
    /// between two players with a login are rated): how much the player's
    /// rating in the game's category moved (+12, -8), and both ratings
    /// before the game. Rounded by the server.
    public var rating: RatedResult?

    public init(
        id: String, yourColor: PieceColor, opponentName: String, opponentIsGuest: Bool, outcome: Outcome,
        termination: Termination, timeControl: TimeControl, plies: Int, finishedAt: Date, rating: RatedResult? = nil
    ) {
        self.id = id
        self.yourColor = yourColor
        self.opponentName = opponentName
        self.opponentIsGuest = opponentIsGuest
        self.outcome = outcome
        self.termination = termination
        self.timeControl = timeControl
        self.plies = plies
        self.finishedAt = finishedAt
        self.rating = rating
    }
}

/// What a rated game did to the ratings of the player looking at it.
public struct RatedResult: Sendable, Hashable {
    /// +12, -8, 0.
    public var change: Int
    public var yourRatingBefore: Int
    public var opponentRatingBefore: Int

    public init(change: Int, yourRatingBefore: Int, opponentRatingBefore: Int) {
        self.change = change
        self.yourRatingBefore = yourRatingBefore
        self.opponentRatingBefore = opponentRatingBefore
    }
}

/// Which games the list shows. Empty fields mean "any"; they combine with AND.
public struct HistoryFilter: Sendable, Hashable {
    /// `.win`, `.loss` or `.draw`; nil for any (`.unknown` is no filter either).
    public var outcome: Outcome?
    /// Exactly this time control; nil for any.
    public var timeControl: TimeControl?
    /// Part of the opponent's name, any case. Spaces around it are dropped
    /// and it is cut to `maxOpponentLength`, as the server requires.
    public var opponent: String {
        didSet { opponent = Self.clean(opponent) }
    }

    /// The server's limit on `opponent`; longer text is refused.
    public static let maxOpponentLength = 32

    public init(outcome: Outcome? = nil, timeControl: TimeControl? = nil, opponent: String = "") {
        self.outcome = outcome == .unknown ? nil : outcome
        self.timeControl = timeControl
        self.opponent = Self.clean(opponent)
    }

    /// Every game.
    public static let all = HistoryFilter()

    /// Some games may be hidden.
    public var isActive: Bool { self != .all }

    private static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxOpponentLength else { return trimmed }
        return String(trimmed.prefix(maxOpponentLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ratings are kept per category, from a time control's estimated length;
/// see `TimeControl.ratingCategory` (ChessClient).
public enum RatingCategory: Sendable, Hashable, CaseIterable, Comparable {
    case bullet, blitz, rapid, classical
}

/// A player's Glicko-2 rating in one category.
public struct Rating: Sendable, Hashable {
    /// Every player starts here; a category without rated games shows it, provisional.
    public static let initial: Double = 1500

    public var category: RatingCategory
    public var rating: Double
    /// How unsure the rating is (350 at the start).
    public var deviation: Double
    public var volatility: Double
    /// Rated games played in the category.
    public var games: Int
    /// Not settled yet (deviation above 110): shown as "1520?".
    public var isProvisional: Bool

    public init(
        category: RatingCategory, rating: Double, deviation: Double, volatility: Double, games: Int,
        isProvisional: Bool
    ) {
        self.category = category
        self.rating = rating
        self.deviation = deviation
        self.volatility = volatility
        self.games = games
        self.isProvisional = isProvisional
    }
}

/// One page of the list, and where the next one starts.
public struct HistoryPage: Sendable, Equatable {
    public var entries: [HistoryEntry]
    /// Nil on the last page.
    public var nextPageToken: String?

    public init(entries: [HistoryEntry], nextPageToken: String?) {
        self.entries = entries
        self.nextPageToken = nextPageToken
    }
}

public struct HistorySummary: Sendable, Equatable {
    public var games, wins, losses, draws: Int

    public init(games: Int, wins: Int, losses: Int, draws: Int) {
        self.games = games
        self.wins = wins
        self.losses = losses
        self.draws = draws
    }
}

/// A game with all its moves, for replaying.
public struct HistoryGame: Sendable, Equatable {
    public var id: String
    public var whiteName: String
    public var blackName: String
    public var yourColor: PieceColor
    public var result: GameResult
    public var termination: Termination
    public var timeControl: TimeControl
    public var moves: [Move]
    public var startedAt: Date
    public var finishedAt: Date
    /// Whether the game counted for ratings.
    public var isRated: Bool
    /// Ratings before the game (rounded); nil when it was not rated.
    public var whiteRatingBefore: Int?
    public var blackRatingBefore: Int?
    /// How the game moved the asking player's rating; nil when it was not rated.
    public var ratingChange: Int?

    public init(
        id: String, whiteName: String, blackName: String, yourColor: PieceColor, result: GameResult,
        termination: Termination, timeControl: TimeControl, moves: [Move], startedAt: Date, finishedAt: Date,
        isRated: Bool = false, whiteRatingBefore: Int? = nil, blackRatingBefore: Int? = nil, ratingChange: Int? = nil
    ) {
        self.id = id
        self.whiteName = whiteName
        self.blackName = blackName
        self.yourColor = yourColor
        self.result = result
        self.termination = termination
        self.timeControl = timeControl
        self.moves = moves
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isRated = isRated
        self.whiteRatingBefore = whiteRatingBefore
        self.blackRatingBefore = blackRatingBefore
        self.ratingChange = ratingChange
    }
}

public enum HistoryError: Error, Equatable, Sendable {
    /// The access token was refused: get a new one and ask again.
    case unauthenticated
    case notFound
    /// The server refused the request as malformed. For a page token: it was
    /// issued for other filters (or is too old); the list starts over.
    case invalidArgument
    /// No answer: no network, or the service is down.
    case unreachable
    case failed(String)
}

/// The history service's calls, as the app uses them. A protocol so the
/// screens' logic can be tested without a server. `accessToken` proves who
/// is asking: each player sees only their own games.
public protocol HistoryAPI: Sendable {
    /// A page of the games `filter` lets through. `pageToken` must come from
    /// a page read with the same filter, or the call fails with `.invalidArgument`.
    func games(pageToken: String?, pageSize: Int, filter: HistoryFilter, accessToken: String)
        async throws(HistoryError) -> HistoryPage
    func summary(accessToken: String) async throws(HistoryError) -> HistorySummary
    func game(id: String, accessToken: String) async throws(HistoryError) -> HistoryGame
    /// The player's ratings, one per category with rated games; the others are absent.
    func ratings(accessToken: String) async throws(HistoryError) -> [Rating]
}

/// chess.history.v1.HistoryService over gRPC (proto/chess/history/v1/history.proto).
public struct HistoryClient: HistoryAPI {
    public let endpoint: GRPCEndpoint
    static let timeout: Duration = .seconds(10)

    public init(endpoint: GRPCEndpoint) {
        self.endpoint = endpoint
    }

    /// From the address the server gives in its bootstrap, e.g. "http://localhost:8082".
    public init?(url: URL) {
        guard let endpoint = GRPCEndpoint(url: url) else { return nil }
        self.endpoint = endpoint
    }

    typealias Service = Chess_History_V1_HistoryService.Client<HTTP2ClientTransport.TransportServices>

    public func games(
        pageToken: String?, pageSize: Int, filter: HistoryFilter = .all, accessToken: String
    ) async throws(HistoryError) -> HistoryPage {
        let request = Chess_History_V1_ListGamesRequest.with {
            $0.pageSize = Int32(pageSize)
            $0.pageToken = pageToken ?? ""
            $0.outcome =
                switch filter.outcome {
                case .win: .win
                case .loss: .loss
                case .draw: .draw
                case .unknown, nil: .unspecified
                }
            // Set only when filtering: the field's presence is the filter.
            if let timeControl = filter.timeControl {
                $0.timeControl = timeControl.wire
            }
            $0.opponent = filter.opponent
        }
        let response = try await call(accessToken) { try await $0.listGames(request, metadata: $1, options: $2) }
        return HistoryPage(
            entries: response.games.compactMap(HistoryEntry.init),
            nextPageToken: response.nextPageToken.isEmpty ? nil : response.nextPageToken)
    }

    public func summary(accessToken: String) async throws(HistoryError) -> HistorySummary {
        let r = try await call(accessToken) { try await $0.getSummary(.init(), metadata: $1, options: $2) }
        return HistorySummary(games: Int(r.games), wins: Int(r.wins), losses: Int(r.losses), draws: Int(r.draws))
    }

    public func game(id: String, accessToken: String) async throws(HistoryError) -> HistoryGame {
        let request = Chess_History_V1_GetGameRequest.with { $0.gameID = id }
        let r = try await call(accessToken) { try await $0.getGame(request, metadata: $1, options: $2) }
        guard let game = HistoryGame(r) else { throw .failed("unreadable game") }
        return game
    }

    public func ratings(accessToken: String) async throws(HistoryError) -> [Rating] {
        let r = try await call(accessToken) { try await $0.getRatings(.init(), metadata: $1, options: $2) }
        return r.ratings.compactMap(Rating.init)
    }

    /// Runs one call with the access token attached and turns a gRPC failure
    /// into a `HistoryError`.
    private func call<Response: Sendable>(
        _ accessToken: String, _ rpc: @Sendable (Service, Metadata, CallOptions) async throws -> Response
    ) async throws(HistoryError) -> Response {
        var headers = Metadata()
        headers.addString("Bearer \(accessToken)", forKey: "authorization")
        let metadata = headers  // A constant: the call runs concurrently and may not share a var.
        do {
            return try await withConnection(to: endpoint) { client in
                try await rpc(Service(wrapping: client), metadata, callOptions(timeout: Self.timeout))
            }
        } catch let error as RPCError {
            switch error.code {
            case .unauthenticated: throw .unauthenticated
            case .notFound: throw .notFound
            case .invalidArgument: throw .invalidArgument
            case .unavailable, .deadlineExceeded, .cancelled: throw .unreachable
            default: throw .failed("\(error.code)")
            }
        } catch {
            throw .unreachable
        }
    }
}

// MARK: - Wire mapping

extension HistoryEntry {
    init?(_ wire: Chess_History_V1_GameEntry) {
        guard let color = PieceColor(wire.yourColor) else { return nil }
        let outcome: Outcome =
            switch wire.outcome {
            case .win: .win
            case .loss: .loss
            case .draw: .draw
            default: .unknown
            }
        self.init(
            id: wire.gameID, yourColor: color, opponentName: wire.opponent.name,
            opponentIsGuest: wire.opponent.userID.isEmpty, outcome: outcome,
            termination: Termination(wire.termination), timeControl: TimeControl(wire.timeControl),
            plies: Int(wire.plies), finishedAt: wire.finishedAt.date,
            rating: wire.rated
                ? RatedResult(
                    change: Int(wire.ratingChange), yourRatingBefore: Int(wire.yourRatingBefore),
                    opponentRatingBefore: Int(wire.opponentRatingBefore))
                : nil)
    }
}

extension HistoryGame {
    init?(_ wire: Chess_History_V1_GetGameResponse) {
        let g = wire.game
        // A move we cannot read would make the replay wrong from there on: refuse the game.
        let moves = g.moves.compactMap(Move.init(uci:))
        guard let color = PieceColor(wire.yourColor), moves.count == g.moves.count else { return nil }
        self.init(
            id: g.gameID, whiteName: g.white.name, blackName: g.black.name, yourColor: color,
            result: GameResult(g.result), termination: Termination(g.termination),
            timeControl: TimeControl(g.timeControl), moves: moves, startedAt: g.startedAt.date,
            finishedAt: g.finishedAt.date, isRated: g.rated,
            whiteRatingBefore: g.rated ? Int(wire.whiteRatingBefore) : nil,
            blackRatingBefore: g.rated ? Int(wire.blackRatingBefore) : nil,
            ratingChange: g.rated ? Int(wire.ratingChange) : nil)
    }
}

extension RatingCategory {
    /// nil for RATING_CATEGORY_UNSPECIFIED and categories this version does not know.
    init?(_ wire: Chess_History_V1_RatingCategory) {
        switch wire {
        case .bullet: self = .bullet
        case .blitz: self = .blitz
        case .rapid: self = .rapid
        case .classical: self = .classical
        default: return nil
        }
    }
}

extension Rating {
    /// nil for a category this version of the app does not know.
    init?(_ wire: Chess_History_V1_Rating) {
        guard let category = RatingCategory(wire.category) else { return nil }
        self.init(
            category: category, rating: wire.rating, deviation: wire.deviation, volatility: wire.volatility,
            games: Int(wire.games), isProvisional: wire.provisional)
    }
}
