import ChessClient
import ChessCore
import ChessModels
import ChessNet
import Foundation
import Observation
import os

/// Glue between the views, the state and the server.
///
/// It owns no rules of its own: `ClientState` decides what an event means,
/// `ConnectionManager` handles the socket, `AppSettings` remembers things.
/// This class turns view actions into commands and feeds server events to
/// the state.
@MainActor
@Observable
final class GameModel {
    enum Health: Equatable {
        case unknown
        case up(latency: Duration)
        case down
    }

    let settings: AppSettings
    /// Everything the server's events change. Views read it; only the model writes.
    private(set) var state = ClientState()
    /// The name the server assigned, e.g. "anonim3f9a1c". Known once connected.
    private(set) var displayName: String?
    private(set) var health: Health = .unknown
    /// Connecting from the lobby, before any screen change.
    private(set) var isConnecting = false
    var timeControl = TimeControl.presets[1]
    /// What the lobby offers; from the server's bootstrap when it answered.
    private(set) var timeControls = TimeControl.presets

    /// Where the app is in starting up; see `start()`.
    enum Launch: Equatable {
        /// The splash screen: checking the version, reconnecting, preparing.
        case loading
        case ready
        /// This version cannot play on this server; `updateURL` leads to the store.
        case updateRequired(updateURL: URL?)
    }

    private(set) var launch: Launch = .loading
    /// A newer version exists but this one may still play: the lobby suggests updating.
    private(set) var updateURL: URL?
    private(set) var isUpdateAvailable = false

    /// How hot the device is, and so how detailed the 3D board may be.
    let power = PowerMonitor()

    private let connectionManager = ConnectionManager()
    /// The account and its tokens; talks to the auth service.
    let accounts: AccountManager
    /// The player's finished games; talks to the history service.
    let history: GameHistory
    /// Our move on its way to the server, timed for Instruments until the answer.
    @ObservationIgnored private var moveInFlight: (ply: Int, interval: OSSignpostIntervalState)?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let accounts = AccountManager()
        self.accounts = accounts
        history = GameHistory(accounts: accounts)
        connectionManager.delegate = self
    }

    var connection: ConnectionManager.Status { connectionManager.status }

    /// Opening the chat marks it read.
    var isChatOpen: Bool {
        get { state.chat.isOpen }
        set { state.chat.isOpen = newValue }
    }

    // MARK: - Account

    /// Why the last attempt to sign in failed, for the sign-in screen.
    private(set) var signInError: String?

    /// Plays without a login. With accounts on the server, that is still an
    /// account (made for this device), so the player keeps one id across
    /// games; without them, a guest as before.
    func playAnonymously() async {
        await signIn(as: .anonymous) { accounts throws(AuthError) in
            if !accounts.hasAccount { try await accounts.signUpAnonymously() }
        }
    }

    /// Signs in with a login, or makes the account first when `isNew`
    /// (`email`, optional, then gets a confirmation code).
    func signIn(login: String, password: String, email: String = "", isNew: Bool) async {
        await signIn(as: .login) { accounts throws(AuthError) in
            if isNew {
                try await accounts.register(login: login, password: password, email: email)
            } else {
                try await accounts.logIn(login: login, password: password)
            }
        }
    }

    /// Sets a new password with the emailed code, and signs in with it.
    func resetPassword(login: String, code: String, newPassword: String) async {
        await signIn(as: .login) { accounts throws(AuthError) in
            try await accounts.resetPassword(login: login, code: code, newPassword: newPassword)
        }
    }

    private func signIn(
        as account: AppSettings.Account, _ request: (AccountManager) async throws(AuthError) -> Void
    ) async {
        signInError = nil
        if accounts.client != nil {
            do {
                try await request(accounts)
            } catch {
                signInError = authErrorText(error)
                return
            }
        }
        // A new identity: the old resume token belongs to someone else.
        settings.resumeToken = nil
        settings.account = account
        await connect()
    }

    /// An anonymous player whose account is on the server, so a login can be
    /// added to it. Without auth, or before the account exists, there is
    /// nothing to add it to.
    var canAddLogin: Bool {
        settings.account == .anonymous && accounts.client != nil && accounts.hasAccount
            && accounts.user?.isAnonymous != false
    }

    /// Adds a login to the anonymous account playing here, from the lobby.
    /// The account stays the same, and so does its game history; the login
    /// becomes the player's name.
    ///
    /// When the anonymous session is over (revoked, or the login was added
    /// already by a request whose answer was lost, which revoked our tokens),
    /// goes back to the sign-in screen, saying why. Either way the error is
    /// thrown, for the form to show.
    func addLogin(login: String, password: String, email: String = "") async throws(AuthError) {
        do {
            try await accounts.upgrade(login: login, password: password, email: email)
        } catch {
            if error.isSignedOut || error == .alreadyRegistered {
                await signOut()
                signInError = authErrorText(error)
            }
            throw error
        }
        settings.account = .login
        displayName = accounts.user?.name ?? login
        // The game server took the name from the token we connected with:
        // connect again with the new one, so opponents see the login too.
        // From the lobby there is no game or room to resume.
        if connectionManager.isConnected, !state.needsResume {
            await connectionManager.disconnect()
            settings.resumeToken = nil
            await connect()
        }
        // Same account, same games: the list beside the lobby is read again
        // with the new session, as after any change of account.
        if history.isAvailable {
            await history.reload()
        }
    }

    /// Forgets the identity and returns to the sign-in screen. Not available
    /// during a game.
    func signOut() async {
        guard !state.isGameInProgress else { return }
        await connectionManager.disconnect()
        await accounts.signOut()
        settings.resumeToken = nil
        settings.account = nil
        displayName = nil
        state = ClientState()
        history.reset()
    }

    // MARK: - Ratings

    /// Ratings are kept for accounts with a login: only their games are
    /// rated, so an anonymous player has none to show.
    var showsRatings: Bool {
        settings.account == .login && history.isAvailable
    }

    /// Reads the ratings again, for players who have them: when the lobby
    /// appears and after a game.
    func refreshRatings() async {
        guard showsRatings else { return }
        await history.refreshRatings()
    }

    // MARK: - Lobby

    func findGame() async {
        guard await connectFromLobby() else { return }
        await send(.findGame(timeControl, side: settings.side))
    }

    func cancelSearch() async {
        await send(.cancelSearch)
    }

    /// Opens a room with the selected time control; the selected side is ours
    /// in the first game.
    func createRoom() async {
        guard await connectFromLobby() else { return }
        await send(.createRoom(timeControl, side: settings.side))
    }

    func joinRoom(code: String) async {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty, await connectFromLobby() else { return }
        await send(.joinRoom(code: code))
    }

    /// Clears the last game and makes sure we are connected.
    private func connectFromLobby() async -> Bool {
        state.prepareForNewGame()
        guard !connectionManager.isConnected else { return true }
        isConnecting = true
        defer { isConnecting = false }
        return await connect()
    }

    // MARK: - Room

    func leaveRoom() async {
        await send(.leaveRoom)
    }

    func setReady(_ ready: Bool) async {
        state.errorMessage = nil
        await send(.setReady(ready))
    }

    // MARK: - Game

    func play(_ move: Move) async {
        guard connection == .online, let sent = state.playLocally(move) else { return }
        if let previous = moveInFlight {  // The answer to it never came.
            Signposts.poi.endInterval("Move", previous.interval, "unanswered")
        }
        let interval = Signposts.poi.beginInterval("Move", id: Signposts.poi.makeSignpostID(), "ply \(sent.ply)")
        moveInFlight = (sent.ply, interval)
        await send(.makeMove(gameID: sent.gameID, ply: sent.ply, move: move))
    }

    func resign() async {
        guard let game = state.game, !game.isOver else { return }
        await send(.resign(gameID: game.id))
    }

    /// Offers a draw, or accepts the opponent's offer.
    func offerDraw() async {
        guard let game = state.game, !game.isOver else { return }
        await send(.offerDraw(gameID: game.id))
    }

    func declineDraw() async {
        guard let game = state.game, !game.isOver else { return }
        await send(.declineDraw(gameID: game.id))
    }

    /// Leaves a finished game: back to the room it was played from, or the lobby.
    func dismissFinishedGame() {
        state.dismissFinishedGame()
    }

    func dismissStartAnnouncement() {
        state.dismissStartAnnouncement()
    }

    // MARK: - Chat

    func sendChat(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isChatClosed, connection == .online, !text.isEmpty else { return }
        state.chat.error = nil
        if let room = state.room {
            await send(.sendRoomChat(code: room.code, text: text))
        } else if let game = state.game {
            await send(.sendChat(gameID: game.id, text: text))
        }
    }

    func setOpponentMuted(_ muted: Bool) {
        state.chat.setOpponentMuted(muted)
    }

    // MARK: - Lifecycle

    /// Runs behind the splash screen, once per launch:
    /// 1. asks the server whether this version may play, and for its settings,
    ///    falling back to the last answer if it does not reply in time;
    /// 2. reconnects if we have played before: should a game or room still be
    ///    going (the app was killed mid-game), we open straight into it rather
    ///    than flashing the lobby first;
    /// 3. prepares the 3D pieces, while step 1 waits for the network.
    /// No step blocks on a missing network: without one the lobby opens with
    /// the server shown as unavailable.
    func start() async {
        guard launch == .loading else { return }
        let signposter = Signposts.poi
        let launchInterval = signposter.beginInterval("Launch")
        defer { signposter.endInterval("Launch", launchInterval) }

        let loader = BootstrapLoader()
        // `async let` starts the request in a child task and moves on: the main
        // thread is free while the request is on the network, so the 3D work
        // below fills that wait instead of adding to it.
        // The URL is read here, on the main actor: the arguments of `async let`
        // are evaluated inside the child task, and reading `settings` there
        // would wait for the main actor, busy with the preload below.
        let url = settings.webSocketURL
        async let fetched = Self.fetchBootstrap(with: loader, url: url)

        // Done for every player, not only those on the 3D board: switching to 3D
        // mid-game would otherwise freeze the screen while RealityKit starts up
        // (about 0.2 s, most of it on its first mesh).
        signposter.withIntervalSignpost("Preload 3D") {
            BoardScene.preload(segments: pieceSegments, quality: power.quality)
        }

        var bootstrap = await fetched
        if let bootstrap {
            settings.lastBootstrap = loader.cache(bootstrap)
        } else {
            bootstrap = loader.cached(in: settings.lastBootstrap)
        }
        if let bootstrap {
            if case .unsupported = bootstrap.client.status {
                launch = .updateRequired(updateURL: bootstrap.client.updateURL)
                return
            }
            isUpdateAvailable = bootstrap.client.status == .outdated
            updateURL = bootstrap.client.updateURL
            timeControls = bootstrap.lobbyTimeControls
            accounts.client = bootstrap.auth.flatMap { AuthClient(url: $0.url) }
            history.client = bootstrap.historyURL.flatMap { HistoryClient(url: $0) }
            if !timeControls.contains(timeControl) {
                timeControl = timeControls[min(1, timeControls.count - 1)]
            }
        }

        await adoptAccount()
        if settings.account != nil, !connectionManager.isConnected {
            let interval = signposter.beginInterval("Reconnect")
            if await connect() {
                // The snapshot of a game or room follows Welcome at once; give it a
                // moment so the first screen is the right one.
                let deadline = ContinuousClock.now + .milliseconds(300)
                while state.screen == .lobby, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            signposter.endInterval("Reconnect", interval)
        }
        launch = .ready
    }

    /// Off the main actor, so the request runs beside the work in `start()`.
    ///
    /// `nonisolated` alone is not enough here: with Approachable Concurrency
    /// (Swift 6.2) a nonisolated async function runs on its caller's actor,
    /// and this caller is the main actor, busy preloading. `@concurrent` asks
    /// for the shared thread pool explicitly.
    @concurrent
    private nonisolated static func fetchBootstrap(with loader: BootstrapLoader, url: URL?) async -> Bootstrap? {
        guard let url else { return nil }
        let interval = Signposts.poi.beginInterval("Bootstrap")
        let bootstrap = await loader.fetch(from: url)
        Signposts.poi.endInterval("Bootstrap", interval, "\(bootstrap == nil ? "no answer" : "answered")")
        return bootstrap
    }

    /// How finely the 3D pieces are cut: the player's choice, capped while the
    /// device is hot or in Low Power Mode.
    var pieceSegments: Int {
        power.quality.pieceSegments(
            preferred: settings.prefersFacetedPieces ? PieceModels.facetedSegments : PieceModels.smoothSegments)
    }

    /// Brings a player signed in before accounts existed, or whose account
    /// is gone, in line with the server: anonymous players get an account
    /// quietly; a login without its token goes back to the sign-in screen.
    private func adoptAccount() async {
        guard let account = settings.account, accounts.client != nil, !accounts.hasAccount else { return }
        switch account {
        case .anonymous:
            do {
                try await accounts.signUpAnonymously()
                settings.resumeToken = nil
            } catch {
                // Auth unreachable: stay as we were; the next connection tries again.
            }
        case .login:
            settings.account = nil
        }
    }

    /// From the update screen: maybe the server's rules changed, or the app was updated.
    func retryStart() async {
        launch = .loading
        await start()
    }

    /// The app came back to the foreground. Sockets are often dead after a
    /// while in the background, so resume a game or room right away.
    func appBecameActive() {
        if state.needsResume, !connectionManager.isConnected, !connectionManager.isReconnecting {
            startReconnecting()
        }
    }

    /// Polls the server's health endpoint until cancelled.
    func monitorHealth() async {
        health = .unknown
        while !Task.isCancelled {
            if let url = URL(string: settings.serverURL) {
                let latency = await ServerHealth.check(url)
                guard !Task.isCancelled else { return }
                health = latency.map { .up(latency: $0) } ?? .down
            } else {
                health = .down
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: - Connection

    @discardableResult
    private func connect() async -> Bool {
        guard let url = settings.webSocketURL else {
            state.errorMessage = String(localized: "The server address must start with ws:// or wss://")
            return false
        }
        let accessToken: String?
        do {
            accessToken = try await accounts.validAccessToken()
        } catch {
            if error.isSignedOut {
                // Revoked: back to the sign-in screen, saying why.
                settings.account = nil
                signInError = authErrorText(error)
            } else {
                state.errorMessage = authErrorText(error)
            }
            return false
        }
        return await connectionManager.connect(to: url, resumeToken: settings.resumeToken, accessToken: accessToken)
    }

    private func startReconnecting() {
        guard let url = settings.webSocketURL else { return }
        connectionManager.keepReconnecting(
            to: url, resumeToken: settings.resumeToken,
            accessToken: { [weak self] in try? await self?.accounts.validAccessToken() },
            while: { [weak self] in self?.state.needsResume ?? false },
            onGiveUp: { [weak self] in self?.state.giveUpReconnecting() }
        )
    }

    private func send(_ command: ClientCommand) async {
        do {
            try await connectionManager.send(command)
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}

extension GameModel: ConnectionManagerDelegate {
    func connectionManager(
        _ manager: ConnectionManager, didWelcomeAs name: String, resumeToken: String, isResumed: Bool
    ) {
        settings.resumeToken = resumeToken
        displayName = name
        state.receiveWelcome(isResumed: isResumed)
    }

    func connectionManager(_ manager: ConnectionManager, didReceive event: ServerEvent) {
        if case .serverError(code: "invalid_token", _) = event {
            // Expired while the device slept, or auth rotated its key: the
            // server closes the connection, and the next one gets a new token.
            accounts.dropAccessToken()
        }
        endMoveInterval(on: event)
        let wasInProgress = state.isGameInProgress
        state.apply(event, now: .now)
        if case .gameOver = event, wasInProgress, !state.isGameInProgress {
            refreshRatingsAfterGame()
        }
    }

    /// The game server hands a finished game to history through its outbox,
    /// so the new rating is there a moment after GameOver, not at once. Asks
    /// shortly after; the lobby asks again when it appears.
    private func refreshRatingsAfterGame() {
        guard showsRatings else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refreshRatings()
        }
    }

    /// Closes the "Move" interval when the server answers our move.
    private func endMoveInterval(on event: ServerEvent) {
        guard let (ply, interval) = moveInFlight else { return }
        switch event {
        case .moveMade(_, ply, _, _, _): Signposts.poi.endInterval("Move", interval, "accepted")
        case .moveRejected(_, ply, _, _): Signposts.poi.endInterval("Move", interval, "rejected")
        case .gameOver, .snapshot: Signposts.poi.endInterval("Move", interval, "game changed")
        default: return
        }
        moveInFlight = nil
    }

    func connectionManager(_ manager: ConnectionManager, didDisconnectWithReason reason: String?) {
        if state.needsResume {
            startReconnecting()
        } else {
            state.loseConnection(reason: reason)
        }
    }
}
