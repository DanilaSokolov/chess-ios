import ChessCore
import ChessNet
import Foundation

/// Everything the server's events change, and the rules for changing it.
///
/// A plain value with no network, UI or clock inside: `GameModel` feeds it
/// events and local actions, the views read it, and tests drive it directly.
/// The current time is passed in where it matters, so tests control it.
public struct ClientState: Sendable {
    public private(set) var game: GameSession?
    public private(set) var room: RoomSession?
    /// The time control being searched for, while matchmaking.
    public private(set) var search: TimeControl?
    public var chat = ChatState()
    public var errorMessage: String?
    /// Until when to show "the game has begun" over a game that a room
    /// countdown led into.
    public private(set) var startAnnouncementEnds: Date?

    /// How long "the game has begun" stays up after a countdown.
    public static let startAnnouncement: Duration = .milliseconds(1500)

    public init() {}

    // MARK: - Screen

    /// What to show. Derived from the state rather than stored next to it,
    /// so "playing without a game" cannot happen.
    public enum Screen: Hashable, Sendable {
        case lobby
        case searching(TimeControl)
        /// In a room, between games.
        case room(RoomSession)
        /// A game in progress or just finished; it stays until dismissed.
        case game(GameSession)

        /// Which screen, ignoring its contents: changes only when the player
        /// moves between screens, not on every move or message.
        public enum Kind: Hashable, Sendable { case lobby, searching, room, game }

        public var kind: Kind {
            switch self {
            case .lobby: .lobby
            case .searching: .searching
            case .room: .room
            case .game: .game
            }
        }
    }

    public var screen: Screen {
        if let game { return .game(game) }
        if let search { return .searching(search) }
        if let room { return .room(room) }
        return .lobby
    }

    public var isGameInProgress: Bool { game.map { !$0.isOver } ?? false }

    /// A dropped connection is worth resuming: there is a game or a room seat to get back to.
    public var needsResume: Bool { isGameInProgress || room != nil }

    // MARK: - Chat
    //
    // One conversation at a time: the room's when in a room (it carries on
    // through the room's games and after them), otherwise the game's.

    public var chatMessages: [ChatMessage] {
        let all = room?.chat ?? game?.state.chat ?? []
        return chat.isOpponentMuted ? all.filter(\.isMine) : all
    }

    /// A game chat closes with its game; a room chat stays open.
    public var isChatClosed: Bool { room == nil && !isGameInProgress }

    /// Whom the chat is with, if known.
    public var chatPartner: String? {
        room.map { $0.state.opponent?.name ?? String(localized: "Room \($0.code)", bundle: .module) }
            ?? game?.state.opponent
    }

    // MARK: - Local actions

    /// Before searching or entering a room: clears the finished game and old errors.
    public mutating func prepareForNewGame() {
        errorMessage = nil
        game = nil
    }

    /// Shows our move right away. Returns the move's game and ply to send, or
    /// nil if it is not our move or not legal. The server's answer confirms it
    /// (MoveMade) or rolls it back (MoveRejected).
    public mutating func playLocally(_ move: Move) -> (gameID: String, ply: Int)? {
        guard var game, game.isMyTurn, let next = game.position.applying(move) else { return nil }
        game.state.position = next
        game.state.moves.append(move)
        self.game = game
        return (game.id, game.moves.count)
    }

    /// Leaves a finished game: back to the room it was played from, or the lobby.
    public mutating func dismissFinishedGame() {
        guard game?.isOver == true else { return }
        game = nil
        if room == nil {
            chat = ChatState()
        } else {
            chat.markRead()  // The room shows its chat inline.
        }
    }

    /// The player tapped "the game has begun" away before it timed out.
    public mutating func dismissStartAnnouncement() {
        startAnnouncementEnds = nil
    }

    // MARK: - Connection

    /// Welcome arrived. If the server did not recognise our token, it has
    /// forgotten our game and our room seat.
    public mutating func receiveWelcome(isResumed: Bool) {
        guard !isResumed else { return }
        finishLocally(message: String(localized: "The server no longer knows this game", bundle: .module))
        loseRoom(
            message: String(
                localized: "The connection was lost for too long; your seat in the room is gone", bundle: .module))
    }

    /// The connection dropped with nothing to resume: a search ends with it.
    public mutating func loseConnection(reason: String?) {
        guard !needsResume else { return }
        guard game == nil else { return }  // A finished game stays on screen.
        search = nil
        if let reason { errorMessage = String(localized: "Connection lost: \(reason)", bundle: .module) }
    }

    /// Reconnecting failed for too long: whatever we were in is gone.
    public mutating func giveUpReconnecting() {
        finishLocally(message: String(localized: "Could not reconnect", bundle: .module))
        loseRoom(message: String(localized: "Could not reconnect", bundle: .module))
    }

    /// Ends the game on our side when the server can no longer tell us how it ended.
    mutating func finishLocally(message: String) {
        guard var game, !game.isOver else { return }
        game.outcome = .init(result: .unknown, termination: .unknown)
        self.game = game
        errorMessage = message
    }

    /// Forgets the room when the server can no longer have kept our seat.
    mutating func loseRoom(message: String) {
        guard room != nil else { return }
        room = nil
        // The room's chat goes with it, even when a finished game is on screen.
        chat = ChatState()
        errorMessage = message
    }

    // MARK: - Server events

    /// Applies one event from the server. `now` is when it arrived.
    public mutating func apply(_ event: ServerEvent, now: Date) {
        switch event {
        case .welcome:
            break  // Identity is the model's business; see `receiveWelcome(isResumed:)`.

        case .searchStarted(let tc):
            search = tc

        case .searchCancelled:
            search = nil

        case .gameStarted(let state):
            // The room's update with the game id follows; until then the
            // countdown is still set, which says this game is the one it led to.
            if let ends = room?.countdownEnds {
                startAnnouncementEnds = max(ends, now).addingTimeInterval(Self.startAnnouncement.seconds)
                room?.countdownEnds = nil
            }
            search = nil
            game = GameSession(state, received: now)
            errorMessage = nil
            if room == nil { chat = ChatState() }

        case .snapshot(let state):
            // Resuming the same game: count what arrived while we were away as unread.
            if let old = game, old.id == state.id, room == nil {
                chat.count(state.chat, after: old.state.chat.last?.seq ?? 0, visible: false)
            }
            search = nil
            game = GameSession(state, received: now)
            errorMessage = nil

        case .moveMade(let id, let ply, let move, let position, let clocks):
            updateGame(id) { game in
                // Our own moves are already on the board; the server's
                // position is authoritative either way.
                if ply > game.moves.count {
                    game.state.moves.append(move)
                }
                game.state.position = position
                game.state.clocks = clocks
                game.clocksReceived = now
            }

        case .moveRejected(let id, let ply, let reason, let position):
            guard game?.id == id else { return }
            updateGame(id) { game in
                game.state.moves = Array(game.moves.prefix(ply - 1))
                game.state.position = position
            }
            errorMessage = String(localized: "Move rejected: \(moveRejectionText(reason))", bundle: .module)

        case .gameOver(let id, let result, let termination, let clocks):
            // After a reconnect the result may arrive twice.
            guard game?.isOver == false else { return }
            updateGame(id) { game in
                if let clocks { game.state.clocks = clocks }
                game.outcome = .init(result: result, termination: termination)
                game.state.drawOfferedBy = nil
                game.opponentDeadline = nil
            }

        case .drawOffer(let id, let offeredBy):
            updateGame(id) { $0.state.drawOfferedBy = offeredBy }

        case .opponentStatus(let id, let connected, let within):
            updateGame(id) { game in
                game.state.opponentConnected = connected
                game.opponentDeadline = connected ? nil : now.addingTimeInterval(within.seconds)
            }

        case .chat(let id, let message):
            guard let game, game.id == id, message.seq > (game.state.chat.last?.seq ?? 0) else { return }
            updateGame(id) { $0.state.chat.append(message) }
            if room == nil { chat.count([message], after: 0, visible: false) }

        case .roomChat(let code, let message):
            guard var room, room.code == code, message.seq > (room.chat.last?.seq ?? 0) else { return }
            room.chat.append(message)
            self.room = room
            chat.count([message], after: 0, visible: screen.kind == .room)

        case .roomState(let state):
            if var room, room.code == state.code {
                if !state.chat.isEmpty {
                    // Resumed: the server sent the history again.
                    chat.count(state.chat, after: room.chat.last?.seq ?? 0, visible: screen.kind == .room)
                    room.chat = state.chat
                }
                room.state = state
                room.countdownEnds = state.startsIn.map { now.addingTimeInterval($0.seconds) }
                self.room = room
            } else {
                var room = RoomSession(state)
                room.countdownEnds = state.startsIn.map { now.addingTimeInterval($0.seconds) }
                self.room = room
                chat = ChatState()
            }

        case .roomLeft(let code):
            guard room?.code == code else { return }
            room = nil
            chat = ChatState()

        case .serverError(let code, let message):
            switch ServerErrorText(code: code, message: message) {
            case .general(let text): errorMessage = text
            case .chat(let text): chat.error = text
            case .ignore: break
            }
        }
    }

    /// Changes the game if `id` is the game being shown; events for any
    /// other game are stale and ignored.
    private mutating func updateGame(_ id: String, _ change: (inout GameSession) -> Void) {
        guard var game, game.id == id else { return }
        change(&game)
        self.game = game
    }
}
