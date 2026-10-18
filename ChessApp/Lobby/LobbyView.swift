import ChessClient
import ChessCore
import ChessNet
import SwiftUI

/// Before a game: who you are, what to play and where.
///
/// A two-column `NavigationSplitView`: the lobby itself in the sidebar, the
/// player's game history beside it. On a wide screen (iPad, the inner display
/// of iPhone Duo, a Mac window, a large iPhone on its side) both columns show,
/// so past games are one tap away while choosing the next one. On a narrow
/// screen (an iPhone, the outer display of iPhone Duo) the split view collapses
/// by itself into a single stack: the lobby, with "Game history" pushing the
/// history onto it. Folding or unfolding iPhone Duo moves between the two
/// without rebuilding anything: it is the same view in both.
struct LobbyView: View {
    @Environment(GameModel.self) private var model
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var roomCode = ""
    @State private var showsEmail = false
    @State private var showsAddLogin = false
    /// Both columns, always: hiding the sidebar would hide the lobby, the very
    /// thing this screen is for, behind a toolbar button.
    @State private var columns = NavigationSplitViewVisibility.doubleColumn
    /// What the collapsed split view shows: the lobby, or the history once the
    /// player opens it. The system sets it back to the lobby on "Back".
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            lobby
                .navigationTitle("Chess")
                #if os(iOS)
                    // Inline: a large title costs a phone on its side a fifth of its height.
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                // Wide enough for the time-control picker without squeezing its segments.
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            history
        }
        // Side by side rather than the sidebar sliding over the history: on an
        // upright iPad or the inner display of iPhone Duo, `.automatic` would
        // hide the lobby until the player asked for it.
        .navigationSplitViewStyle(.balanced)
        // Restarts the polling, with a fresh check, whenever the address changes.
        .task(id: model.settings.serverURL) { await model.monitorHealth() }
        // Whenever the lobby appears (a game just changed them) and when the
        // player gets a login.
        .task(id: model.showsRatings) { await model.refreshRatings() }
        .sheet(isPresented: $showsEmail) {
            EmailView()
                #if os(macOS)
                    .frame(minWidth: 420, minHeight: 420)
                #endif
        }
        .sheet(isPresented: $showsAddLogin) {
            AddLoginView()
                #if os(macOS)
                    .frame(minWidth: 420, minHeight: 460)
                #endif
        }
    }

    /// The split view is a single stack: the history is not on screen until opened.
    ///
    /// `NavigationSplitView` collapses exactly when the window's horizontal size
    /// class is compact. Read here, outside the split view: the sidebar column
    /// may be given a compact size class of its own even when both columns show.
    private var isCollapsed: Bool {
        #if os(iOS)
            return horizontalSizeClass == .compact
        #else
            return false  // A Mac window always shows both columns.
        #endif
    }

    /// The detail column: the history, or why there is none.
    @ViewBuilder
    private var history: some View {
        if model.history.isAvailable {
            HistoryView()
        } else {
            ContentUnavailableView {
                Label("No game history", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(
                    model.history.client == nil
                        ? "This server does not keep finished games."
                        : "Finished games are kept for players with an account."
                )
            }
        }
    }

    /// The lobby proper: the sidebar, or the whole screen when collapsed.
    @ViewBuilder
    private var lobby: some View {
        @Bindable var model = model
        @Bindable var settings = model.settings
        Form {
            if model.isUpdateAvailable {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A new version is available")
                            if let url = model.updateURL {
                                Link("Update", destination: url)
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.down.app")
                    }
                }
            }
            Section("Player") {
                HStack {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName ?? "anonim······")
                            .font(.body.monospaced())
                            .foregroundStyle(model.displayName == nil ? .secondary : .primary)
                        Text(
                            model.displayName == nil
                                ? "The server assigns a name when you connect"
                                : model.settings.account == .login ? "Signed in with a login" : "Anonymous play"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Leave") { Task { await model.signOut() } }
                }
                if model.showsRatings {
                    RatingsLine(
                        ratings: model.history.ratings,
                        categories: RatingCategory.categories(of: model.timeControls),
                        selected: model.timeControl.ratingCategory)
                }
                if model.canAddLogin {
                    Button {
                        showsAddLogin = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Create a login")
                                // Where ratings are kept at all: the hint leads to the login that gives one.
                                if model.history.isAvailable {
                                    Text("Ratings need a login")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "person.badge.key")
                        }
                    }
                } else if model.settings.account == .anonymous, model.history.isAvailable {
                    Text("Ratings need a login")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.settings.account == .login {
                    Button {
                        showsEmail = true
                    } label: {
                        Label("Email and password reset", systemImage: "envelope")
                    }
                }
                // Beside the lobby on a wide screen; a step away on a narrow one.
                if model.history.isAvailable, isCollapsed {
                    Button {
                        compactColumn = .detail
                    } label: {
                        Label("Game history", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            Section("Side") {
                Picker("Side", selection: $settings.side) {
                    Text("Random").tag(PieceColor?.none)
                    Text("White").tag(PieceColor?.some(.white))
                    Text("Black").tag(PieceColor?.some(.black))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Time control") {
                Picker("Time control", selection: $model.timeControl) {
                    ForEach(model.timeControls) { Text($0.description).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section {
                TextField(text: $settings.serverURL, prompt: Text(verbatim: "ws://host:8080/ws")) {
                    Text("Server")
                }
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
            } header: {
                HStack {
                    Text("Server")
                    Spacer()
                    HealthIndicator(health: model.health)
                }
            }
            if let error = model.state.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button {
                    Task { await model.findGame() }
                } label: {
                    if model.isConnecting {
                        ProgressView()
                    } else {
                        Text("Find a game").frame(maxWidth: .infinity)
                    }
                }
                .disabled(model.isConnecting)
                .buttonStyle(.borderedProminent)
            }
            Section {
                Button("Create a room") {
                    Task { await model.createRoom() }
                }
                .disabled(model.isConnecting)
                HStack {
                    TextField("Room code", text: $roomCode)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            .submitLabel(.join)
                        #endif
                        .onSubmit(join)
                    Button("Join", action: join)
                        .disabled(roomCode.trimmingCharacters(in: .whitespaces).isEmpty || model.isConnecting)
                }
            } header: {
                Text("Play with a friend")
            } footer: {
                Text(
                    "Create a room and send the code to a friend. The time control and your side in the first game come from the settings above; after that, colours alternate."
                )
            }
        }
        .formStyle(.grouped)
        // The form scrolls, so on a phone on its side the keyboard for the
        // server address or the room code can be swiped away.
        .scrollDismissesKeyboard(.interactively)
    }

    private func join() {
        let code = roomCode
        Task { await model.joinRoom(code: code) }
    }
}

private struct HealthIndicator: View {
    let health: GameModel.Health

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).textCase(nil)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch health {
        case .unknown: .gray
        case .up: .green
        case .down: .red
        }
    }

    private var label: String {
        switch health {
        case .unknown: String(localized: "checking…")
        case .up(let latency): String(localized: "available · \(Int(latency.seconds * 1000)) ms")
        case .down: String(localized: "unavailable")
        }
    }
}
