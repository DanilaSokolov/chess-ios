import ChessClient
import ChessCore
import ChessNet
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The player's finished games: totals on top, then the games, newest first,
/// loaded a page at a time as the list scrolls. A game opens for replaying.
/// A search field finds games by the opponent's name, and a menu in the
/// toolbar narrows them by outcome and time control.
///
/// The detail column of the lobby's split view (see `LobbyView`), not a sheet:
/// beside the lobby on a wide screen, pushed over it on a narrow one. Its own
/// stack keeps "list → replay" inside the column, as Apple recommends for a
/// detail column with drill-down.
struct HistoryView: View {
    @Environment(GameModel.self) private var model
    /// The search field as typed. It becomes the filter's opponent 300 ms
    /// after the last keystroke, so typing a name asks the server once, not
    /// once per letter.
    @State private var searchText = ""

    /// How long typing has to pause before the search is sent.
    private static let searchDelay: Duration = .milliseconds(300)

    var body: some View {
        let history = model.history
        NavigationStack {
            List {
                if let summary = history.summary, summary.games > 0 {
                    Section {
                        SummaryRow(summary: summary)
                    }
                }
                if let error = history.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(history.entries) { entry in
                        NavigationLink(value: entry.id) {
                            HistoryRow(entry: entry)
                        }
                        .onAppear {
                            // The last row came into view: fetch the next page.
                            if entry.id == history.entries.last?.id {
                                Task { await history.loadMore() }
                            }
                        }
                    }
                    if history.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
            .overlay {
                if history.entries.isEmpty, !history.isLoading, history.errorMessage == nil {
                    if history.filter.isActive {
                        ContentUnavailableView {
                            Label("No games match", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try another name, outcome or time control.")
                        } actions: {
                            Button("Reset filters") { apply(.all) }
                        }
                    } else {
                        ContentUnavailableView(
                            "No games yet", systemImage: "clock.arrow.circlepath",
                            description: Text("Finished games appear here."))
                    }
                }
            }
            .navigationTitle("Game history")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: Text("Opponent"))
            .task(id: searchText) {
                let opponent = HistoryFilter(opponent: searchText).opponent
                guard opponent != history.filter.opponent else { return }
                // A new keystroke cancels this task, and the sleep with it.
                guard (try? await Task.sleep(for: Self.searchDelay)) != nil else { return }
                var filter = history.filter
                filter.opponent = opponent
                await history.setFilter(filter)
            }
            // The view is made anew each time the lobby shows it: show the filter the list has.
            .onAppear { searchText = history.filter.opponent }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HistoryFilterMenu(filter: history.filter, timeControls: model.timeControls, apply: apply)
                }
            }
            .navigationDestination(for: String.self) { id in
                GameReplayView(gameID: id)
            }
            .refreshable { await history.reload() }
            // Every time the lobby shows it, so a game just finished is already listed.
            .task { await history.reload() }
        }
    }

    /// Shows the games `filter` lets through, from the first page. The search
    /// field follows when the filter's opponent changes from here (a reset).
    private func apply(_ filter: HistoryFilter) {
        if filter.opponent != HistoryFilter(opponent: searchText).opponent {
            searchText = filter.opponent
        }
        let history = model.history
        Task { await history.setFilter(filter) }
    }
}

/// The toolbar's filter button: outcome and time control, each a submenu,
/// and a reset while anything is filtered. The icon is filled while the
/// list is filtered, so a short list does not look like a short history.
private struct HistoryFilterMenu: View {
    let filter: HistoryFilter
    /// The lobby's time controls: the ones games are played with.
    let timeControls: [TimeControl]
    let apply: (HistoryFilter) -> Void

    var body: some View {
        Menu {
            Picker(selection: outcome) {
                Text("All").tag(Outcome?.none)
                Text("Wins").tag(Outcome?.some(.win))
                Text("Losses").tag(Outcome?.some(.loss))
                Text("Draws").tag(Outcome?.some(.draw))
            } label: {
                Label("Outcome", systemImage: "flag.checkered")
            }
            .pickerStyle(.menu)
            Picker(selection: timeControl) {
                Text("All").tag(TimeControl?.none)
                ForEach(timeControls) { Text(verbatim: $0.description).tag(TimeControl?.some($0)) }
            } label: {
                Label("Time control", systemImage: "clock")
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Divider()
                Button("Reset filters", systemImage: "xmark.circle") { apply(.all) }
            }
        } label: {
            Label(
                "Filter",
                systemImage: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var outcome: Binding<Outcome?> {
        Binding {
            filter.outcome
        } set: { value in
            var next = filter
            next.outcome = value
            apply(next)
        }
    }

    private var timeControl: Binding<TimeControl?> {
        Binding {
            filter.timeControl
        } set: { value in
            var next = filter
            next.timeControl = value
            apply(next)
        }
    }
}

private struct SummaryRow: View {
    let summary: HistorySummary

    var body: some View {
        HStack {
            stat(summary.games, "Games", .primary)
            stat(summary.wins, "Wins", .green)
            stat(summary.losses, "Losses", .red)
            stat(summary.draws, "Draws", .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: Int, _ title: LocalizedStringKey, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(value)")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            OutcomeBadge(outcome: entry.outcome)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: entry.yourColor == .white ? "circle" : "circle.fill")
                        .font(.caption2)
                        .accessibilityLabel(entry.yourColor == .white ? Text("as White") : Text("as Black"))
                    Text(entry.opponentName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.finishedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rating = entry.rating {
                    RatingChange(change: rating.change)
                }
            }
        }
    }

    /// "3+2 · checkmate · 12 moves"
    private var details: String {
        let moves = (entry.plies + 1) / 2
        return "\(entry.timeControl) · \(entry.termination.text) · "
            + String(localized: "\(moves) moves")
    }
}

/// "+12" in green, "−8" in red: how a rated game moved the player's rating.
private struct RatingChange: View {
    let change: Int

    var body: some View {
        Text(verbatim: ratingChangeText(change))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .accessibilityLabel(Text("Rating \(ratingChangeText(change))"))
    }

    private var color: Color {
        change > 0 ? .green : change < 0 ? .red : .secondary
    }
}

/// "W", "L" or "=" in a coloured circle: the outcome at a glance.
private struct OutcomeBadge: View {
    let outcome: Outcome

    var body: some View {
        Text(verbatim: symbol)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color, in: Circle())
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch outcome {
        case .win: "+"
        case .loss: "−"
        case .draw: "="
        case .unknown: "?"
        }
    }

    private var color: Color {
        switch outcome {
        case .win: .green
        case .loss: .red
        case .draw, .unknown: .gray
        }
    }

    private var label: Text {
        switch outcome {
        case .win: Text("Win")
        case .loss: Text("Loss")
        case .draw: Text("Draw")
        case .unknown: Text("Game interrupted")
        }
    }
}

/// One finished game, stepped through move by move on a board.
struct GameReplayView: View {
    @Environment(GameModel.self) private var model
    let gameID: String

    @State private var game: HistoryGame?
    @State private var positions: [Position] = []
    /// The moves in SAN ("Nf3"), as far as they replay; see `moveText`.
    @State private var san: [String] = []
    /// The game as PGN, for sharing and copying; nil if its moves cannot be written.
    @State private var pgn: String?
    @State private var ply = 0
    @State private var error: String?

    /// The arrangement on screen, so a resize near the point where both give
    /// the same board does not flip it (see `preferredArrangement(for:current:)`).
    /// Nil until the view has a size: the first one is taken as is, not animated.
    @State private var arrangement: Arrangement?

    var body: some View {
        Group {
            if let game {
                replay(game)
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        // Names are not translated: verbatim, so they do not land in the String Catalog.
        .navigationTitle(Text(verbatim: game.map(Self.title) ?? ""))
        .toolbar {
            if let game, let pgn {
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(
                        item: PGNFile(text: pgn, fileName: game.pgnFileName),
                        preview: SharePreview(game.pgnFileName)
                    ) {
                        Label("Share PGN", systemImage: "square.and.arrow.up")
                    }
                    Button("Copy PGN", systemImage: "doc.on.doc") { copy(pgn) }
                }
            }
        }
        .task {
            do {
                let loaded = try await model.history.game(id: gameID)
                positions = loaded.positions
                // `positions` stops at a move that does not apply; so does SAN.
                san = sanPrefix(of: loaded.moves)
                pgn = try? loaded.pgn(site: URL(string: model.settings.serverURL)?.host() ?? "?")
                ply = positions.count - 1  // Open on the final position.
                game = loaded
            } catch {
                self.error = historyErrorText(error as? HistoryError ?? .unreachable)
            }
        }
    }

    /// "alice – Bob", with the ratings before the game when it was rated:
    /// "alice (1520) – Bob (1487)".
    private static func title(_ game: HistoryGame) -> String {
        func player(_ name: String, _ rating: Int?) -> String {
            rating.map { "\(name) (\($0))" } ?? name
        }
        return "\(player(game.whiteName, game.whiteRatingBefore)) – \(player(game.blackName, game.blackRatingBefore))"
    }

    private func copy(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Room the text and buttons around the board take, padding included:
    /// below it when stacked (four lines and their spacing), beside it when
    /// side by side (a column wide enough for the four step buttons).
    private static let stackedChrome: CGFloat = 190
    private static let besideChrome: CGFloat = 260
    private static let besidePanelWidth: CGFloat = 200

    /// Where the text and buttons go: under the board or beside it.
    /// `nonisolated`: compared and stored from SwiftUI's callbacks, and the
    /// app's types are on the main actor by default.
    private nonisolated enum Arrangement: Equatable, Sendable {
        case stacked
        case beside
    }

    /// The board with the text and buttons under it or, when that gives a
    /// bigger board, beside it: a phone on its side (or the outer display of
    /// iPhone Duo) is wide and only about 400 pt tall, and stacking would leave
    /// the board a postage stamp. Decided from the space the view actually has,
    /// which also covers a narrow detail column or a short Mac window. The
    /// board itself always fits the smaller side (`BoardView` is square, `.fit`).
    ///
    /// Why `AnyLayout` and not `if beside { HStack } else { VStack }`: the two
    /// branches of an `if` are different views, so rotating the phone or
    /// resizing the window would throw the board away and make a new one.
    /// Here the children are the same two views in the same order either
    /// way, the board and the panel under or beside it; only the layout
    /// changes, so the board lives on and the move animates. That is also why
    /// the result is the first line of the panel when stacked too, under the
    /// board, and no longer above it.
    private func replay(_ game: HistoryGame) -> some View {
        let beside = arrangement == .beside
        let layout = beside ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 16))
        return layout {
            board(game)
            VStack(spacing: 16) {
                result(game)
                moveLine(game)
                controls
                details(game)
            }
            .frame(minWidth: beside ? Self.besidePanelWidth : nil)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            let next = Self.preferredArrangement(for: size, current: arrangement)
            guard next != arrangement else { return }
            if arrangement == nil {
                arrangement = next
            } else {
                withAnimation(.smooth) { arrangement = next }
            }
        }
        .animation(.snappy, value: ply)
    }

    /// Stacked or beside for a view of `size`: whichever gives the bigger
    /// board, with the game screen's hysteresis in favour of `current`
    /// (`GameScreenGeometry.switchMargin`): the other arrangement has to win
    /// by 5% to replace it, so dragging a window edge back and forth across
    /// the point where both are equal does not flip the screen on every point.
    private static func preferredArrangement(for size: CGSize, current: Arrangement?) -> Arrangement {
        let stackedBoard = max(0, min(size.width, size.height - stackedChrome))
        let besideBoard = max(0, min(size.height, size.width - besideChrome))
        let margin = GameScreenGeometry.switchMargin
        if current == .beside {
            return besideBoard < stackedBoard / margin ? .stacked : .beside
        }
        return besideBoard > stackedBoard * margin ? .beside : .stacked
    }

    /// "You won · checkmate", and for a rated game how it moved your rating: "· +12".
    private func result(_ game: HistoryGame) -> some View {
        let change = game.ratingChange.map { " · \(ratingChangeText($0))" } ?? ""
        return Text(verbatim: "\(resultText(game.result, for: game.yourColor)) · \(game.termination.text)\(change)")
            .font(.headline)
            .multilineTextAlignment(.center)
    }

    private func board(_ game: HistoryGame) -> some View {
        BoardView(
            position: positions[ply], perspective: game.yourColor,
            lastMove: ply > 0 ? game.moves[ply - 1] : nil, isInteractive: false)
    }

    private func moveLine(_ game: HistoryGame) -> some View {
        Text(ply == 0 ? String(localized: "Starting position") : moveText(game, ply: ply))
            .font(.body.monospaced())
            .contentTransition(.numericText())
    }

    private func details(_ game: HistoryGame) -> some View {
        Text(
            verbatim:
                "\(game.timeControl.description) · \(game.finishedAt.formatted(date: .abbreviated, time: .shortened))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    /// "12. Nf3", or "12… Nf6" for Black. A move SAN could not be written
    /// for (the rules here and the server's disagree) is shown in UCI.
    private func moveText(_ game: HistoryGame, ply: Int) -> String {
        let number = (ply + 1) / 2
        let dots = ply.isMultiple(of: 2) ? "…" : "."
        let move = ply <= san.count ? san[ply - 1] : game.moves[ply - 1].uci
        return "\(number)\(dots) \(move)"
    }

    private var controls: some View {
        let last = positions.count - 1
        return HStack(spacing: 24) {
            step("backward.end.fill", "First move", to: 0, enabled: ply > 0)
            step("backward.fill", "Previous move", to: ply - 1, enabled: ply > 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
            step("forward.fill", "Next move", to: ply + 1, enabled: ply < last)
                .keyboardShortcut(.rightArrow, modifiers: [])
            step("forward.end.fill", "Last move", to: last, enabled: ply < last)
        }
        .font(.title2)
        .buttonStyle(.borderless)
    }

    private func step(_ icon: String, _ label: LocalizedStringKey, to target: Int, enabled: Bool) -> some View {
        Button {
            ply = target
        } label: {
            Image(systemName: icon)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
