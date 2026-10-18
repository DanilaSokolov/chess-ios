import ChessCore
import ChessNet
import Foundation
import Observation

/// The player's finished games, for the history screen: a list read a page at
/// a time (only the games the filter lets through), totals, single games for
/// replaying, and the player's ratings.
@MainActor
@Observable
public final class GameHistory {
    public private(set) var entries: [HistoryEntry] = []
    public private(set) var summary: HistorySummary?
    public private(set) var isLoading = false
    /// More pages wait on the server.
    public private(set) var hasMore = false
    /// Why the last load failed, in the player's language.
    public private(set) var errorMessage: String?
    /// Which games the list shows; change it with `setFilter(_:)`.
    public private(set) var filter = HistoryFilter.all
    /// The player's ratings by category; a category without rated games is
    /// absent (show it as 1500, provisional: see `ratingText`).
    public private(set) var ratings: [RatingCategory: Rating] = [:]

    /// The history service, at the address from the server's bootstrap. Nil:
    /// the server keeps no history.
    public var client: (any HistoryAPI)?

    @ObservationIgnored private let accounts: AccountManager
    @ObservationIgnored private var nextPageToken: String?
    /// Counts list loads. A load that finds a newer number when its answer
    /// arrives was overtaken (the filter changed, or the list was reloaded)
    /// and its answer is dropped: it belongs to a list no longer on screen.
    @ObservationIgnored private var generation = 0
    static let pageSize = 20

    public init(accounts: AccountManager) {
        self.accounts = accounts
    }

    /// History is kept for accounts only: a guest has nobody to keep it for.
    public var isAvailable: Bool { client != nil && accounts.hasAccount }

    /// The first page and the totals, from scratch: on opening the screen,
    /// on pull to refresh, and when the filter changes. Starts over even if a
    /// load is under way; that load's answer is then ignored.
    public func reload() async {
        generation += 1
        let current = generation
        let filter = self.filter
        isLoading = true
        errorMessage = nil
        let result: Result<(HistoryPage, HistorySummary), HistoryError>
        do {
            async let page = authorized { client, token throws(HistoryError) in
                try await client.games(pageToken: nil, pageSize: Self.pageSize, filter: filter, accessToken: token)
            }
            async let totals = authorized { client, token throws(HistoryError) in
                try await client.summary(accessToken: token)
            }
            let (first, sum) = try await (page, totals)
            result = .success((first, sum))
        } catch {
            result = .failure(error as? HistoryError ?? .unreachable)
        }
        guard current == generation else { return }  // Overtaken: a newer load owns the list.
        isLoading = false
        switch result {
        case .success(let (first, sum)):
            entries = first.entries
            nextPageToken = first.nextPageToken
            hasMore = first.nextPageToken != nil
            summary = sum
        case .failure(let error):
            errorMessage = historyErrorText(error)
        }
    }

    /// The next page, when the list is scrolled to its end.
    public func loadMore() async {
        guard !isLoading, let token = nextPageToken else { return }
        let current = generation
        let filter = self.filter
        isLoading = true
        let result: Result<HistoryPage, HistoryError>
        do {
            let page = try await authorized { client, access throws(HistoryError) in
                try await client.games(pageToken: token, pageSize: Self.pageSize, filter: filter, accessToken: access)
            }
            result = .success(page)
        } catch {
            result = .failure(error)
        }
        guard current == generation else { return }  // The filter changed meanwhile: not this list's page.
        isLoading = false
        switch result {
        case .success(let page):
            // The server's paging never repeats a game; this guards against a
            // double tap loading the same page twice.
            let known = Set(entries.map(\.id))
            entries += page.entries.filter { !known.contains($0.id) }
            nextPageToken = page.nextPageToken
            hasMore = page.nextPageToken != nil
        case .failure(.invalidArgument):
            // The server no longer takes the token (it is only good with the
            // filters it was issued for): read the list again from the start.
            await reload()
        case .failure(let error):
            errorMessage = historyErrorText(error)
        }
    }

    /// Shows only the games `filter` lets through, from the first page: the
    /// old page token belongs to the old filter. Nothing happens if the
    /// filter is the same.
    public func setFilter(_ filter: HistoryFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        entries = []
        nextPageToken = nil
        hasMore = false
        await reload()
    }

    /// Reads the player's ratings again: when the lobby appears and after a
    /// game. If history does not answer, the ratings already shown stay.
    public func refreshRatings() async {
        guard let list = try? await authorized({ client, token throws(HistoryError) in
            try await client.ratings(accessToken: token)
        }) else { return }
        ratings = Dictionary(list.map { ($0.category, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The rating in `category`; nil when the player has no rated games there.
    public func rating(for category: RatingCategory) -> Rating? {
        ratings[category]
    }

    /// Forgets everything read for the account: on signing out, so the next
    /// player does not see the last one's games or ratings.
    public func reset() {
        generation += 1
        entries = []
        summary = nil
        isLoading = false
        hasMore = false
        errorMessage = nil
        filter = .all
        ratings = [:]
        nextPageToken = nil
    }

    /// One game with its moves.
    public func game(id: String) async throws(HistoryError) -> HistoryGame {
        try await authorized { client, token throws(HistoryError) in try await client.game(id: id, accessToken: token) }
    }

    /// Calls history with a valid access token. If history refuses it (it
    /// expired a moment ago, or auth rotated its key), gets a fresh one and
    /// tries once more.
    private func authorized<T: Sendable>(
        _ call: (any HistoryAPI, String) async throws(HistoryError) -> T
    ) async throws(HistoryError) -> T {
        guard let client else { throw .unreachable }
        for attempt in 1...2 {
            let token: String
            do {
                guard let valid = try await accounts.validAccessToken() else { throw HistoryError.unauthenticated }
                token = valid
            } catch {
                throw .unauthenticated
            }
            do {
                return try await call(client, token)
            } catch .unauthenticated where attempt == 1 {
                accounts.dropAccessToken()
            }
        }
        throw .unauthenticated
    }
}

/// What to tell the player when history cannot be read.
public func historyErrorText(_ error: HistoryError) -> String {
    switch error {
    case .unreachable:
        String(localized: "The history server is not answering. Pull down to try again.", bundle: .module)
    case .unauthenticated:
        String(localized: "Sign in to see your games.", bundle: .module)
    case .notFound:
        String(localized: "This game is not in your history.", bundle: .module)
    case .invalidArgument:
        String(localized: "The history server did not accept the request.", bundle: .module)
    case .failed(let reason):
        String(localized: "Could not load the history (\(reason)).", bundle: .module)
    }
}

extension HistoryGame {
    /// The position after each half-move, the start included: positions[0] is
    /// the initial position, positions[moves.count] the final one. For
    /// stepping through the game.
    public var positions: [Position] {
        var all = [Position.starting]
        for move in moves {
            // The server checked every move when it was played; a move that does
            // not apply here would mean the two rule books disagree. Stop there.
            guard let next = all.last?.applying(move) else { break }
            all.append(next)
        }
        return all
    }
}
