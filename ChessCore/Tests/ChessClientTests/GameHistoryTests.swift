import ChessCore
import ChessNet
import Foundation
import Synchronization
import Testing

@testable import ChessClient

/// History without a server: 45 games, pages of the asked size, and a token
/// it can be told to refuse once.
final class FakeHistory: HistoryAPI {
    let tokensSeen = Mutex<[String]>([])
    let refuseNextToken = Mutex(false)

    static func entry(_ i: Int) -> HistoryEntry {
        HistoryEntry(
            id: "g\(i)", yourColor: i.isMultiple(of: 2) ? .white : .black, opponentName: "Bot 3+2",
            opponentIsGuest: true, outcome: .win, termination: .checkmate,
            timeControl: TimeControl(minutes: 3, increment: 2), plies: 4,
            finishedAt: Date(timeIntervalSince1970: TimeInterval(1000 - i)))
    }

    private func check(_ token: String) throws(HistoryError) {
        tokensSeen.withLock { $0.append(token) }
        if refuseNextToken.withLock({ refuse in
            defer { refuse = false }
            return refuse
        }) {
            throw .unauthenticated
        }
    }

    func games(pageToken: String?, pageSize: Int, accessToken: String) async throws(HistoryError) -> HistoryPage {
        try check(accessToken)
        let start = Int(pageToken ?? "0") ?? 0
        let end = min(start + pageSize, 45)
        return HistoryPage(entries: (start..<end).map(Self.entry), nextPageToken: end < 45 ? "\(end)" : nil)
    }

    func summary(accessToken: String) async throws(HistoryError) -> HistorySummary {
        try check(accessToken)
        return HistorySummary(games: 45, wins: 45, losses: 0, draws: 0)
    }

    func game(id: String, accessToken: String) async throws(HistoryError) -> HistoryGame {
        try check(accessToken)
        throw .notFound
    }
}

/// An account manager that already has a session.
@MainActor
private func signedIn() async throws -> AccountManager {
    let auth = FakeAuth()
    auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
    auth.reply("refresh", .success(FakeAuth.session("2", refresh: "r2")))
    let accounts = AccountManager(store: MemorySecretStore())
    accounts.client = auth
    try await accounts.signUpAnonymously()
    return accounts
}

@MainActor
struct GameHistoryTests {
    @Test func notAvailableWithoutAServerOrAnAccount() async throws {
        let history = GameHistory(accounts: AccountManager(store: MemorySecretStore()))
        #expect(!history.isAvailable)
        history.client = FakeHistory()
        #expect(!history.isAvailable, "a guest has no history")
    }

    @Test func pagesLoadUntilTheEnd() async throws {
        let history = GameHistory(accounts: try await signedIn())
        history.client = FakeHistory()
        await history.reload()
        #expect(history.entries.count == 20 && history.hasMore)
        #expect(history.summary?.games == 45)
        await history.loadMore()
        await history.loadMore()
        #expect(history.entries.count == 45 && !history.hasMore)
        #expect(Set(history.entries.map(\.id)).count == 45, "no game twice")
        await history.loadMore()  // Past the end: nothing happens.
        #expect(history.entries.count == 45)
    }

    /// The token expired between being checked and being used: one more try
    /// with a fresh one, not an error on screen.
    @Test func refusedTokenIsRenewedOnce() async throws {
        let fake = FakeHistory()
        let history = GameHistory(accounts: try await signedIn())
        history.client = fake
        fake.refuseNextToken.withLock { $0 = true }
        await history.loadMore()  // Nothing loaded yet: no-op.
        await history.reload()
        #expect(history.errorMessage == nil)
        #expect(history.entries.count == 20)
        #expect(fake.tokensSeen.withLock { $0 }.contains("access-2"), "a renewed token was used")
    }

    @Test func missingGameIsReported() async throws {
        let history = GameHistory(accounts: try await signedIn())
        history.client = FakeHistory()
        await #expect(throws: HistoryError.notFound) {
            try await history.game(id: "nope")
        }
        #expect(historyErrorText(.notFound) == "This game is not in your history.")
    }

    @Test func replayHasAPositionPerHalfMove() throws {
        let game = HistoryGame(
            id: "g", whiteName: "a", blackName: "b", yourColor: .white, result: .blackWins, termination: .checkmate,
            timeControl: TimeControl(minutes: 3, increment: 2),
            moves: ["f2f3", "e7e5", "g2g4", "d8h4"].compactMap(Move.init(uci:)),
            startedAt: .now, finishedAt: .now)
        let positions = game.positions
        #expect(positions.count == 5)
        #expect(positions[0] == .starting)
        #expect(positions[4].status == .checkmate(winner: .black), "fool's mate")
    }
}
