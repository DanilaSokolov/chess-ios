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

    public init(
        id: String, yourColor: PieceColor, opponentName: String, opponentIsGuest: Bool, outcome: Outcome,
        termination: Termination, timeControl: TimeControl, plies: Int, finishedAt: Date
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

    public init(
        id: String, whiteName: String, blackName: String, yourColor: PieceColor, result: GameResult,
        termination: Termination, timeControl: TimeControl, moves: [Move], startedAt: Date, finishedAt: Date
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
    }
}

public enum HistoryError: Error, Equatable, Sendable {
    /// The access token was refused: get a new one and ask again.
    case unauthenticated
    case notFound
    /// No answer: no network, or the service is down.
    case unreachable
    case failed(String)
}

/// The history service's calls, as the app uses them. A protocol so the
/// screens' logic can be tested without a server. `accessToken` proves who
/// is asking: each player sees only their own games.
public protocol HistoryAPI: Sendable {
    func games(pageToken: String?, pageSize: Int, accessToken: String) async throws(HistoryError) -> HistoryPage
    func summary(accessToken: String) async throws(HistoryError) -> HistorySummary
    func game(id: String, accessToken: String) async throws(HistoryError) -> HistoryGame
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

    public func games(pageToken: String?, pageSize: Int, accessToken: String) async throws(HistoryError)
        -> HistoryPage
    {
        let request = Chess_History_V1_ListGamesRequest.with {
            $0.pageSize = Int32(pageSize)
            $0.pageToken = pageToken ?? ""
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
            plies: Int(wire.plies), finishedAt: wire.finishedAt.date)
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
            finishedAt: g.finishedAt.date)
    }
}
