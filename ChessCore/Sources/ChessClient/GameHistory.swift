import ChessCore
import ChessNet
import Foundation
import Observation

/// The player's finished games, for the history screen: a list read a page at
/// a time, totals, and single games for replaying.
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

    /// The history service, at the address from the server's bootstrap. Nil:
    /// the server keeps no history.
    public var client: (any HistoryAPI)?

    @ObservationIgnored private let accounts: AccountManager
    @ObservationIgnored private var nextPageToken: String?
    static let pageSize = 20

    public init(accounts: AccountManager) {
        self.accounts = accounts
    }

    /// History is kept for accounts only: a guest has nobody to keep it for.
    public var isAvailable: Bool { client != nil && accounts.hasAccount }

    /// The first page and the totals, from scratch: on opening the screen and
    /// on pull to refresh.
    public func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            async let page = authorized { client, token throws(HistoryError) in
                try await client.games(pageToken: nil, pageSize: Self.pageSize, accessToken: token)
            }
            async let totals = authorized { client, token throws(HistoryError) in
                try await client.summary(accessToken: token)
            }
            let (first, sum) = try await (page, totals)
            entries = first.entries
            nextPageToken = first.nextPageToken
            hasMore = first.nextPageToken != nil
            summary = sum
        } catch {
            errorMessage = historyErrorText(error as? HistoryError ?? .unreachable)
        }
    }

    /// The next page, when the list is scrolled to its end.
    public func loadMore() async {
        guard !isLoading, let token = nextPageToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await authorized { client, access throws(HistoryError) in
                try await client.games(pageToken: token, pageSize: Self.pageSize, accessToken: access)
            }
            // The server's paging never repeats a game; this guards against a
            // double tap loading the same page twice.
            let known = Set(entries.map(\.id))
            entries += page.entries.filter { !known.contains($0.id) }
            nextPageToken = page.nextPageToken
            hasMore = page.nextPageToken != nil
        } catch {
            errorMessage = historyErrorText(error)
        }
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
