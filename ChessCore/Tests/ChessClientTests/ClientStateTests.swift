import ChessCore
import ChessNet
import Foundation
import Testing

@testable import ChessClient

// MARK: - Fixtures

let t0 = Date(timeIntervalSince1970: 1_000_000)
let blitz = TimeControl(minutes: 3, increment: 2)
let fullClocks = Clocks(white: .seconds(180), black: .seconds(180))

func gameState(_ id: String = "g1", color: PieceColor = .white, chat: [ChatMessage] = []) -> GameState {
    GameState(
        id: id, color: color, opponent: "bob", timeControl: blitz, position: .starting, clocks: fullClocks, chat: chat)
}

func roomState(
    code: String = "ROOM42", gameID: String? = nil, chat: [ChatMessage] = [], startsIn: Duration? = nil
) -> RoomState {
    RoomState(
        code: code, timeControl: blitz,
        members: [.init(name: "ann", isYou: true, isHost: true), .init(name: "bob")],
        gameID: gameID, chat: chat, startsIn: startsIn)
}

func line(_ seq: Int, mine: Bool = false) -> ChatMessage {
    ChatMessage(seq: seq, author: mine ? "ann" : "bob", isMine: mine, text: "#\(seq)", sentAt: t0)
}

extension ClientState {
    /// Applies events in order, all arriving at `t0`.
    mutating func apply(_ events: ServerEvent...) {
        for event in events { apply(event, now: t0) }
    }
}

// MARK: - Screens

@Test func screenFollowsTheState() {
    var s = ClientState()
    #expect(s.screen == .lobby)
    s.apply(.searchStarted(blitz))
    #expect(s.screen == .searching(blitz))
    s.apply(.gameStarted(gameState()))
    #expect(s.screen.kind == .game, "a game ends the search")
    #expect(s.search == nil)
    s.apply(.gameOver(gameID: "g1", result: .draw, termination: .drawAgreement, clocks: nil))
    #expect(s.screen.kind == .game, "a finished game stays until dismissed")
    s.dismissFinishedGame()
    #expect(s.screen == .lobby)
}

@Test func roomGameReturnsToTheRoom() {
    var s = ClientState()
    s.apply(.roomState(roomState()))
    #expect(s.screen.kind == .room)
    s.apply(.gameStarted(gameState()), .roomState(roomState(gameID: "g1")))
    #expect(s.screen.kind == .game)
    s.apply(
        .gameOver(gameID: "g1", result: .whiteWins, termination: .resignation, clocks: nil),
        .roomState(roomState()))
    #expect(s.screen.kind == .game, "the result stays on screen")
    s.dismissFinishedGame()
    #expect(s.screen.kind == .room)
}

@Test func gameInProgressCannotBeDismissed() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()))
    s.dismissFinishedGame()
    #expect(s.screen.kind == .game)
}

// MARK: - Moves

@Test func ownMoveIsShownAtOnceAndNotRepeated() throws {
    var s = ClientState()
    s.apply(.gameStarted(gameState()))
    let e4 = Move(uci: "e2e4")!
    let played = s.playLocally(e4)
    let sent = try #require(played)
    #expect(sent.gameID == "g1" && sent.ply == 1)
    #expect(s.game?.moves == [e4])

    let after = Position.starting.applying(e4)!
    s.apply(.moveMade(gameID: "g1", ply: 1, move: e4, position: after, clocks: fullClocks))
    #expect(s.game?.moves == [e4], "the echo of our own move is not added twice")
}

@Test func notOurTurnIsRefusedLocally() {
    var s = ClientState()
    s.apply(.gameStarted(gameState(color: .black)))
    #expect(s.playLocally(Move(uci: "e2e4")!) == nil)
    #expect(s.game?.moves.isEmpty == true)
}

@Test func rejectedMoveIsRolledBack() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()))
    _ = s.playLocally(Move(uci: "e2e4")!)
    s.apply(.moveRejected(gameID: "g1", ply: 1, reason: "illegal move", position: .starting))
    #expect(s.game?.moves.isEmpty == true)
    #expect(s.game?.position == .starting)
    #expect(s.errorMessage == "Move rejected: That move is not allowed")
}

@Test func eventsForAnotherGameAreIgnored() {
    var s = ClientState()
    s.apply(.gameStarted(gameState("g1")))
    s.apply(
        .moveRejected(gameID: "old", ply: 1, reason: "late", position: .starting),
        .gameOver(gameID: "old", result: .draw, termination: .drawAgreement, clocks: nil))
    #expect(s.errorMessage == nil)
    #expect(s.game?.isOver == false)
}

@Test func repeatedGameOverKeepsTheFirstResult() {
    var s = ClientState()
    s.apply(
        .gameStarted(gameState()),
        .gameOver(gameID: "g1", result: .whiteWins, termination: .checkmate, clocks: nil),
        .gameOver(gameID: "g1", result: .draw, termination: .timeout, clocks: nil))
    #expect(s.game?.outcome == .init(result: .whiteWins, termination: .checkmate))
}

@Test func runningClockCountsDown() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()))
    let game = s.game!
    #expect(game.remaining(.white, at: t0.addingTimeInterval(10)) == .seconds(170), "white is to move")
    #expect(game.remaining(.black, at: t0.addingTimeInterval(10)) == .seconds(180))
}

// MARK: - Connection

@Test func serverForgettingUsEndsTheGameAndTheRoom() {
    var s = ClientState()
    s.apply(.roomState(roomState()), .gameStarted(gameState()))
    s.receiveWelcome(isResumed: false)
    #expect(s.game?.outcome == .init(result: .unknown, termination: .unknown))
    #expect(s.room == nil)
    #expect(s.errorMessage != nil)
}

@Test func resumedWelcomeChangesNothing() {
    var s = ClientState()
    s.apply(.roomState(roomState()), .gameStarted(gameState()))
    s.receiveWelcome(isResumed: true)
    #expect(s.isGameInProgress && s.room != nil && s.errorMessage == nil)
}

@Test func lostConnectionEndsASearch() {
    var s = ClientState()
    s.apply(.searchStarted(blitz))
    #expect(!s.needsResume)
    s.loseConnection(reason: "timeout")
    #expect(s.screen == .lobby)
    #expect(s.errorMessage == "Connection lost: timeout")
}

@Test func lostConnectionKeepsAFinishedGameOnScreen() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()), .gameOver(gameID: "g1", result: .draw, termination: .stalemate, clocks: nil))
    s.loseConnection(reason: "timeout")
    #expect(s.screen.kind == .game)
    #expect(s.errorMessage == nil)
}

// MARK: - Chat

@Test func gameChatCountsUnreadUntilOpened() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()), .chat(gameID: "g1", line(1)), .chat(gameID: "g1", line(2, mine: true)))
    #expect(s.chat.unread == 1, "only the opponent's message")
    s.chat.isOpen = true
    #expect(s.chat.unread == 0)
    s.apply(.chat(gameID: "g1", line(3)))
    #expect(s.chat.unread == 0, "an open chat is read as it arrives")
}

@Test func duplicateChatLinesAreDropped() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()), .chat(gameID: "g1", line(1)), .chat(gameID: "g1", line(1)))
    #expect(s.chatMessages.count == 1)
}

@Test func snapshotCountsWhatArrivedWhileAway() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()), .chat(gameID: "g1", line(1)))
    s.chat.isOpen = true
    s.chat.isOpen = false
    s.apply(.snapshot(gameState(chat: [line(1), line(2), line(3)])))
    #expect(s.chat.unread == 2)
}

@Test func mutingHidesTheOpponentAndItsUnread() {
    var s = ClientState()
    s.apply(.gameStarted(gameState()), .chat(gameID: "g1", line(1)), .chat(gameID: "g1", line(2, mine: true)))
    s.chat.setOpponentMuted(true)
    #expect(s.chat.unread == 0)
    #expect(s.chatMessages.map(\.seq) == [2])
    s.apply(.chat(gameID: "g1", line(3)))
    #expect(s.chat.unread == 0)
}

@Test func chatRefusalsGoToTheChat() {
    var s = ClientState()
    s.apply(.serverError(code: "chat_rate_limited", message: "too fast"))
    #expect(s.chat.error == "Too fast — wait a couple of seconds")
    #expect(s.errorMessage == nil)
    s.apply(.serverError(code: "no_such_game", message: "late"))
    #expect(s.errorMessage == nil, "a harmless race is not shown")
    s.apply(.serverError(code: "weird", message: "something"))
    #expect(s.errorMessage == "The server refused the request (weird)", "the server's English is not shown")
    s.apply(.serverError(code: "unknown_message", message: "unknown message type"))
    #expect(s.errorMessage == "The app and the server do not understand each other — please update the app")
}

@Test func unknownRejectionReasonIsNotShownRaw() {
    #expect(moveRejectionText("illegal move") == "That move is not allowed")
    #expect(moveRejectionText("king is shy") == "The server did not accept the move")
}

/// The bug seen on 14.10: messages read inline in the room still showed up as unread.
@Test func roomChatShownInlineIsNotUnread() {
    var s = ClientState()
    s.apply(.roomState(roomState()), .roomChat(code: "ROOM42", line(1)))
    #expect(s.screen.kind == .room)
    #expect(s.chat.unread == 0)
}

/// The bug seen on 14.10: after the room was lost, its unread badge stayed on the finished game.
@Test func losingTheRoomClearsItsUnread() {
    var s = ClientState()
    s.apply(
        .roomState(roomState()), .gameStarted(gameState()), .roomChat(code: "ROOM42", line(1)),
        .gameOver(gameID: "g1", result: .draw, termination: .drawAgreement, clocks: nil))
    #expect(s.chat.unread == 1, "read nowhere yet: the game screen shows only a preview")
    s.receiveWelcome(isResumed: false)
    #expect(s.chat.unread == 0)
    #expect(s.chatMessages.isEmpty)
}

// MARK: - Countdown

@Test func countdownEndsRelativeToArrival() {
    var s = ClientState()
    s.apply(.roomState(roomState(startsIn: .seconds(3))), now: t0)
    #expect(s.room?.countdownEnds == t0.addingTimeInterval(3))
    s.apply(.roomState(roomState()), now: t0.addingTimeInterval(1))
    #expect(s.room?.countdownEnds == nil, "cancelled: the update has no countdown")
}

@Test func gameFromCountdownIsAnnounced() {
    var s = ClientState()
    s.apply(.roomState(roomState(startsIn: .seconds(3))), now: t0)
    s.apply(.gameStarted(gameState()), now: t0.addingTimeInterval(3))
    #expect(s.startAnnouncementEnds == t0.addingTimeInterval(4.5))
    #expect(s.room?.countdownEnds == nil)
}

@Test func earlyGameStartStillShowsTheWholeCountdown() {
    // The game arrived a little before our own count reached zero: the
    // announcement runs from zero, not from arrival.
    var s = ClientState()
    s.apply(.roomState(roomState(startsIn: .seconds(3))), now: t0)
    s.apply(.gameStarted(gameState()), now: t0.addingTimeInterval(2.9))
    #expect(s.startAnnouncementEnds == t0.addingTimeInterval(4.5))
}

@Test func matchedGameIsNotAnnounced() {
    var s = ClientState()
    s.apply(.searchStarted(blitz), .gameStarted(gameState()))
    #expect(s.startAnnouncementEnds == nil)
}

@Test func startAnnouncementCanBeDismissed() {
    var s = ClientState()
    s.apply(.roomState(roomState(startsIn: .seconds(3))), now: t0)
    s.apply(.gameStarted(gameState()), now: t0.addingTimeInterval(3))
    s.dismissStartAnnouncement()
    #expect(s.startAnnouncementEnds == nil)
    #expect(s.screen.kind == .game, "only the label goes, the game stays")
}
