import ChessCore
import Foundation
import Testing

@testable import ChessNet

/// End-to-end tests against a running server. Skipped unless
/// CHESS_SERVER_URL is set, e.g.:
///
///     CHESS_SERVER_URL=ws://localhost:8080/ws swift test -c release
let liveServerURL = ProcessInfo.processInfo.environment["CHESS_SERVER_URL"].flatMap(URL.init(string:))

/// Wraps a client's event stream with a per-event timeout.
final class LivePlayer {
    let client: GameClient
    private var iterator: AsyncStream<ClientEvent>.Iterator

    init(url: URL, name: String?, resumeToken: String? = nil) async {
        client = GameClient(url: url, playerName: name, resumeToken: resumeToken)
        iterator = client.events.makeAsyncIterator()
        await client.connect()
    }

    /// Waits up to 10 seconds for the next server event. On timeout the
    /// connection is closed, which ends the stream with `.disconnected`.
    func next() async throws -> ServerEvent {
        let watchdog = Task { [client] in
            try await Task.sleep(for: .seconds(10))
            await client.disconnect()
        }
        defer { watchdog.cancel() }
        // `next(isolation:)` keeps the iterator where this method runs; plain
        // `next()` would send it to the shared pool, which the compiler rejects.
        switch await iterator.next(isolation: #isolation) {
        case .server(let e):
            return e
        case .disconnected(let reason):
            throw LiveError.disconnected(reason.map { "\($0)" } ?? "closed or timed out")
        case nil:
            throw LiveError.disconnected("stream ended")
        }
    }
}

enum LiveError: Error {
    case disconnected(String)
    case timeout
    case unexpected(ServerEvent)
}

@Suite(.enabled(if: liveServerURL != nil), .serialized)
struct LiveServerTests {
    @Test func twoSwiftClientsPlayFoolsMate() async throws {
        let url = try #require(liveServerURL)
        let tc = TimeControl(minutes: 7, increment: 7)  // A queue no one else uses.
        let a = await LivePlayer(url: url, name: "swift-a")
        let b = await LivePlayer(url: url, name: "swift-b")

        #expect(try await isWelcome(a.next()))
        #expect(try await isWelcome(b.next()))
        try await a.client.send(.findGame(tc, side: nil))
        _ = try await a.next()  // searchStarted
        try await b.client.send(.findGame(tc, side: nil))
        _ = try await b.next()  // searchStarted

        guard case .gameStarted(let ga) = try await a.next(),
            case .gameStarted(let gb) = try await b.next(), ga.id == gb.id
        else { throw LiveError.timeout }
        let id = ga.id
        let (white, black) = ga.color == .white ? (a, b) : (b, a)

        var position = Position.starting
        for (i, uci) in ["f2f3", "e7e5", "g2g4", "d8h4"].enumerated() {
            let move = Move(uci: uci)!
            try await (i % 2 == 0 ? white : black).client.send(.makeMove(gameID: id, ply: i + 1, move: move))
            position = try #require(position.applying(move))
            for p in [white, black] {
                let event = try await p.next()
                guard case .moveMade(_, let ply, let made, let serverPosition, _) = event else {
                    throw LiveError.unexpected(event)
                }
                #expect(ply == i + 1 && made == move)
                #expect(serverPosition.board == position.board)
            }
        }
        for p in [white, black] {
            guard case .gameOver(let gid, let result, let termination, let clocks) = try await p.next() else {
                throw LiveError.timeout
            }
            #expect(gid == id && result == .blackWins && termination == .checkmate && clocks != nil)
        }
    }

    /// Drops a connection mid-game and resumes it with the token from Welcome.
    @Test func resumeAfterDisconnect() async throws {
        let url = try #require(liveServerURL)
        let tc = TimeControl(minutes: 8, increment: 8)
        let a = await LivePlayer(url: url, name: "swift-stay")
        let b = await LivePlayer(url: url, name: nil)  // Anonymous.
        _ = try await a.next()
        guard case .welcome(let playerID, let anonName, let token, false) = try await b.next() else {
            throw LiveError.timeout
        }
        #expect(anonName == "anonim" + playerID.prefix(6))
        try await a.client.send(.findGame(tc, side: nil))
        _ = try await a.next()
        try await b.client.send(.findGame(tc, side: nil))
        _ = try await b.next()
        guard case .gameStarted(let ga) = try await a.next(), case .gameStarted(let gb) = try await b.next() else {
            throw LiveError.timeout
        }

        // White moves so the snapshot has something to restore.
        let white = ga.color == .white ? a : b
        try await white.client.send(.makeMove(gameID: ga.id, ply: 1, move: Move(uci: "e2e4")!))
        _ = try await a.next()
        _ = try await b.next()

        await b.client.disconnect()
        guard case .opponentStatus(ga.id, false, let grace) = try await a.next() else { throw LiveError.timeout }
        #expect(grace > .zero)

        let back = await LivePlayer(url: url, name: nil, resumeToken: token)
        guard case .welcome(playerID, anonName, token, true) = try await back.next() else {
            Issue.record("expected the same identity to resume")
            return
        }
        guard case .snapshot(let state) = try await back.next() else { throw LiveError.timeout }
        #expect(state.id == ga.id && state.color == gb.color && state.moves == [Move(uci: "e2e4")!])
        guard case .opponentStatus(ga.id, true, _) = try await a.next() else { throw LiveError.timeout }

        try await a.client.send(.resign(gameID: ga.id))
        for p in [a, back] {
            guard case .gameOver(ga.id, _, .resignation, _) = try await p.next() else { throw LiveError.timeout }
        }
    }

    /// Plays random moves from our generator against `go run ./cmd/bot -tc 9+9`.
    /// The server validates with an independent library, so any rules bug in
    /// ChessCore shows up as a rejected move. Enable with CHESS_BOT=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHESS_BOT"] != nil))
    func randomGameAgainstBot() async throws {
        let url = try #require(liveServerURL)
        let me = await LivePlayer(url: url, name: "swift-random")
        _ = try await me.next()  // welcome
        try await me.client.send(.findGame(TimeControl(minutes: 9, increment: 9), side: nil))
        _ = try await me.next()  // searchStarted

        guard case .gameStarted(let game) = try await me.next() else { throw LiveError.timeout }
        let (id, color) = (game.id, game.color)
        var position = game.position
        var ply = 0
        while true {
            // With no legal moves (mate or stalemate) GameOver follows the
            // last MoveMade, and next() times out if the server disagrees.
            if position.sideToMove == color, let move = position.legalMoves().randomElement() {
                try await me.client.send(.makeMove(gameID: id, ply: ply + 1, move: move))
            }
            switch try await me.next() {
            case .moveMade(_, let p, _, let serverPosition, _):
                ply = p
                position = serverPosition
            case .gameOver(_, let result, let termination, _):
                print("random game over after \(ply) plies: \(result) by \(termination)")
                #expect(result != .unknown)
                return
            case let event:
                throw LiveError.unexpected(event)
            }
        }
    }
}

private func isWelcome(_ e: ServerEvent) -> Bool {
    if case .welcome = e { return true }
    return false
}
