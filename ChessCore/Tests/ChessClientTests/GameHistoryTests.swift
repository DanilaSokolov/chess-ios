import ChessCore
import ChessNet
import Foundation
import Synchronization
import Testing

@testable import ChessClient

/// History without a server: 45 games, pages of the asked size, filters, and
/// a token it can be told to refuse once. Page tokens remember the filter
/// they were issued for, and are refused with another one, as the server does.
final class FakeHistory: HistoryAPI {
    let tokensSeen = Mutex<[String]>([])
    let refuseNextToken = Mutex(false)
    /// Every page token is refused as INVALID_ARGUMENT (say, the server changed how it makes them).
    let refusePageTokens = Mutex(false)
    /// Every list request: its page token and filter.
    let requests = Mutex<[(pageToken: String?, filter: HistoryFilter)]>([])
    /// A list request with this opponent filter waits until `release()`.
    let holdOpponent = Mutex<String?>(nil)
    private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let holding = AsyncStream<Void>.makeStream()
    let ratingsToReturn = Mutex<[Rating]>([])

    static let total = 45

    /// Outcomes go win, loss, draw; opponents Alice, Alice, Bob, Bob, Bot;
    /// the first 30 games are 3+2, the rest 10+0.
    static func entry(_ i: Int) -> HistoryEntry {
        HistoryEntry(
            id: "g\(i)", yourColor: i.isMultiple(of: 2) ? .white : .black,
            opponentName: ["Alice", "Alice", "Bob", "Bob", "Bot 3+2"][i % 5],
            opponentIsGuest: i % 5 == 4, outcome: [Outcome.win, .loss, .draw][i % 3], termination: .checkmate,
            timeControl: i < 30 ? TimeControl(minutes: 3, increment: 2) : TimeControl(minutes: 10, increment: 0),
            plies: 4, finishedAt: Date(timeIntervalSince1970: TimeInterval(1000 - i)))
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

    private static func key(_ filter: HistoryFilter) -> String {
        "\(filter.outcome.map { "\($0)" } ?? "-")|\(filter.timeControl?.description ?? "-")|\(filter.opponent)"
    }

    func games(pageToken: String?, pageSize: Int, filter: HistoryFilter, accessToken: String)
        async throws(HistoryError) -> HistoryPage
    {
        try check(accessToken)
        requests.withLock { $0.append((pageToken, filter)) }
        if holdOpponent.withLock({ $0 }) == filter.opponent {
            await withCheckedContinuation { continuation in
                held.withLock { $0 = continuation }
                holding.continuation.yield()
            }
        }
        var start = 0
        if let pageToken {
            let parts = pageToken.split(separator: "#", omittingEmptySubsequences: false)
            guard !refusePageTokens.withLock({ $0 }), parts.count == 2, parts[0] == Self.key(filter),
                let offset = Int(parts[1])
            else { throw .invalidArgument }
            start = offset
        }
        let matching = (0..<Self.total).map(Self.entry).filter { entry in
            (filter.outcome == nil || entry.outcome == filter.outcome)
                && (filter.timeControl == nil || entry.timeControl == filter.timeControl)
                && (filter.opponent.isEmpty || entry.opponentName.localizedCaseInsensitiveContains(filter.opponent))
        }
        let end = min(start + pageSize, matching.count)
        return HistoryPage(
            entries: Array(matching[min(start, end)..<end]),
            nextPageToken: end < matching.count ? "\(Self.key(filter))#\(end)" : nil)
    }

    /// Returns once a held request is waiting.
    func waitUntilHeld() async {
        var waiting = holding.stream.makeAsyncIterator()
        _ = await waiting.next()
    }

    /// Lets the held request answer.
    func release() {
        held.withLock {
            $0?.resume()
            $0 = nil
        }
    }

    func summary(accessToken: String) async throws(HistoryError) -> HistorySummary {
        try check(accessToken)
        return HistorySummary(games: 45, wins: 15, losses: 15, draws: 15)
    }

    func game(id: String, accessToken: String) async throws(HistoryError) -> HistoryGame {
        try check(accessToken)
        throw .notFound
    }

    func ratings(accessToken: String) async throws(HistoryError) -> [Rating] {
        try check(accessToken)
        return ratingsToReturn.withLock { $0 }
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

    // MARK: - Filters

    @Test func changingTheFilterStartsFromTheFirstPage() async throws {
        let fake = FakeHistory()
        let history = GameHistory(accounts: try await signedIn())
        history.client = fake
        await history.reload()
        await history.loadMore()
        #expect(history.entries.count == 40 && history.hasMore)

        await history.setFilter(HistoryFilter(outcome: .win))
        let last = try #require(fake.requests.withLock { $0.last })
        #expect(last.pageToken == nil, "the old token belongs to the old filter")
        #expect(last.filter.outcome == .win)
        #expect(history.entries.count == 15 && !history.hasMore)
        #expect(history.entries.allSatisfy { $0.outcome == .win })
        #expect(history.filter.isActive)

        // Filters combine: wins against Bob in 3+2.
        await history.setFilter(
            HistoryFilter(outcome: .win, timeControl: TimeControl(minutes: 3, increment: 2), opponent: "  bob "))
        #expect(history.filter.opponent == "bob", "spaces dropped")
        #expect(!history.entries.isEmpty)
        #expect(
            history.entries.allSatisfy {
                $0.outcome == .win && $0.opponentName == "Bob" && $0.timeControl.description == "3+2"
            })

        // The same filter again: nothing is asked.
        let asked = fake.requests.withLock { $0.count }
        await history.setFilter(history.filter)
        #expect(fake.requests.withLock { $0.count } == asked)

        await history.setFilter(.all)
        #expect(history.entries.count == 20 && !history.filter.isActive)
    }

    @Test func pagingWithAFilterKeepsTheFilter() async throws {
        let fake = FakeHistory()
        let history = GameHistory(accounts: try await signedIn())
        history.client = fake
        await history.setFilter(HistoryFilter(opponent: "ali"))  // 18 of the 45 games.
        #expect(history.entries.count == 18 && !history.hasMore)
        await history.setFilter(HistoryFilter(timeControl: TimeControl(minutes: 3, increment: 2)))  // 30 games.
        #expect(history.entries.count == 20 && history.hasMore)
        await history.loadMore()
        #expect(history.entries.count == 30 && !history.hasMore)
        #expect(history.errorMessage == nil, "the token came with the same filter")
        #expect(fake.requests.withLock { $0.last?.filter.timeControl } == TimeControl(minutes: 3, increment: 2))
    }

    /// The opponent field changed while the list for the old text was on its
    /// way: that answer arrives last but must not replace the newer list.
    @Test func staleAnswerIsIgnored() async throws {
        let fake = FakeHistory()
        let history = GameHistory(accounts: try await signedIn())
        history.client = fake
        fake.holdOpponent.withLock { $0 = "bot" }
        let slow = Task { await history.setFilter(HistoryFilter(opponent: "bot")) }
        await fake.waitUntilHeld()
        #expect(history.isLoading)

        await history.setFilter(HistoryFilter(opponent: "alice"))
        #expect(history.entries.count == 18 && !history.isLoading)

        fake.release()
        await slow.value
        #expect(history.filter.opponent == "alice")
        #expect(history.entries.count == 18, "the list for \"bot\" was dropped")
        #expect(history.entries.allSatisfy { $0.opponentName == "Alice" })
        #expect(!history.isLoading)
    }

    @Test func refusedPageTokenReloadsFromTheStart() async throws {
        let fake = FakeHistory()
        let history = GameHistory(accounts: try await signedIn())
        history.client = fake
        await history.reload()
        #expect(history.entries.count == 20)
        fake.refusePageTokens.withLock { $0 = true }
        await history.loadMore()
        let requests = fake.requests.withLock { $0 }
        #expect(requests.count == 3, "first page, refused page, first page again")
        #expect(requests[1].pageToken != nil && requests[2].pageToken == nil)
        #expect(history.errorMessage == nil, "not an error for the player")
        #expect(history.entries.count == 20 && history.hasMore)
        #expect(Set(history.entries.map(\.id)).count == 20, "no game twice")
    }

    @Test func opponentFilterIsCutToTheServersLimit() {
        let filter = HistoryFilter(opponent: String(repeating: "a", count: 40))
        #expect(filter.opponent.count == HistoryFilter.maxOpponentLength)
        #expect(HistoryFilter(outcome: .unknown) == .all, "unknown is no outcome filter")
    }

    // MARK: - Ratings

    @Test func ratingsAreReadByCategory() async throws {
        let fake = FakeHistory()
        let history = GameHistory(accounts: try await signedIn())
        history.client = fake
        fake.ratingsToReturn.withLock {
            $0 = [
                Rating(
                    category: .blitz, rating: 1520.4, deviation: 80, volatility: 0.06, games: 30, isProvisional: false),
                Rating(
                    category: .rapid, rating: 1487.6, deviation: 160, volatility: 0.06, games: 2, isProvisional: true),
            ]
        }
        await history.refreshRatings()
        #expect(ratingText(history.rating(for: .blitz)) == "1520")
        #expect(ratingText(history.rating(for: .rapid)) == "1488?")
        #expect(history.rating(for: .bullet) == nil)
        #expect(ratingText(history.rating(for: .bullet)) == "1500?", "not played yet: the starting rating")

        history.reset()
        #expect(history.ratings.isEmpty && history.entries.isEmpty)
    }
}
