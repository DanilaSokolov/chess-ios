import ChessClient
import ChessCore
import ChessNet
import SwiftUI

/// The player's finished games: totals on top, then the games, newest first,
/// loaded a page at a time as the list scrolls. A game opens for replaying.
///
/// The detail column of the lobby's split view (see `LobbyView`), not a sheet:
/// beside the lobby on a wide screen, pushed over it on a narrow one. Its own
/// stack keeps "list → replay" inside the column, as Apple recommends for a
/// detail column with drill-down.
struct HistoryView: View {
    @Environment(GameModel.self) private var model

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
                    ContentUnavailableView(
                        "No games yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Finished games appear here."))
                }
            }
            .navigationTitle("Game history")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: String.self) { id in
                GameReplayView(gameID: id)
            }
            .refreshable { await history.reload() }
            // Every time the lobby shows it, so a game just finished is already listed.
            .task { await history.reload() }
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
            Text(entry.finishedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "3+2 · checkmate · 12 moves"
    private var details: String {
        let moves = (entry.plies + 1) / 2
        return "\(entry.timeControl) · \(entry.termination.text) · "
            + String(localized: "\(moves) moves")
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
        .navigationTitle(Text(verbatim: game.map { "\($0.whiteName) – \($0.blackName)" } ?? ""))
        .task {
            do {
                let loaded = try await model.history.game(id: gameID)
                positions = loaded.positions
                ply = positions.count - 1  // Open on the final position.
                game = loaded
            } catch {
                self.error = historyErrorText(error as? HistoryError ?? .unreachable)
            }
        }
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

    private func result(_ game: HistoryGame) -> some View {
        Text(verbatim: "\(resultText(game.result, for: game.yourColor)) · \(game.termination.text)")
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

    /// "12. Nf3" style, in UCI: "12. g1f3", or "12… g8f6" for Black.
    private func moveText(_ game: HistoryGame, ply: Int) -> String {
        let number = (ply + 1) / 2
        let dots = ply.isMultiple(of: 2) ? "…" : "."
        return "\(number)\(dots) \(game.moves[ply - 1].uci)"
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
