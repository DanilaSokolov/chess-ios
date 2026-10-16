import ChessCore
import ChessProto
import Foundation
internal import SwiftProtobuf

/// Must match `gateway.ProtocolVersion` on the server.
public let protocolVersion: UInt32 = 4

public struct TimeControl: Sendable, Hashable, Identifiable, CustomStringConvertible {
    public var initialSeconds: Int
    public var incrementSeconds: Int

    public init(minutes: Int, increment: Int) {
        initialSeconds = minutes * 60
        incrementSeconds = increment
    }

    public init(initialSeconds: Int, incrementSeconds: Int) {
        self.initialSeconds = initialSeconds
        self.incrementSeconds = incrementSeconds
    }

    public var id: String { description }
    public var description: String { "\(initialSeconds / 60)+\(incrementSeconds)" }

    public static let presets: [TimeControl] = [
        TimeControl(minutes: 1, increment: 0),
        TimeControl(minutes: 3, increment: 2),
        TimeControl(minutes: 5, increment: 0),
        TimeControl(minutes: 10, increment: 0),
        TimeControl(minutes: 15, increment: 10),
    ]
}

/// Remaining time of both players when a message was sent. During a game the
/// clock of the side to move is running.
public struct Clocks: Sendable, Hashable {
    public var white: Duration
    public var black: Duration

    public init(white: Duration, black: Duration) {
        self.white = white
        self.black = black
    }

    public subscript(color: PieceColor) -> Duration {
        color == .white ? white : black
    }
}

public enum GameResult: Sendable, Hashable {
    case whiteWins, blackWins, draw, unknown
}

public enum Termination: Sendable, Hashable {
    case checkmate, stalemate, insufficientMaterial, threefoldRepetition
    case fiftyMoveRule, resignation, abandonment, timeout, drawAgreement, unknown
}

/// A line in a game or room chat. `seq` increases within the game or room,
/// so duplicates (a snapshot overlapping live messages) can be dropped.
public struct ChatMessage: Sendable, Hashable, Identifiable {
    public var seq: Int
    /// The author's side; nil in room chat.
    public var from: PieceColor?
    public var author: String
    /// This player wrote it.
    public var isMine: Bool
    public var text: String
    public var sentAt: Date

    public init(seq: Int, from: PieceColor? = nil, author: String = "", isMine: Bool, text: String, sentAt: Date) {
        self.seq = seq
        self.from = from
        self.author = author
        self.isMine = isMine
        self.text = text
        self.sentAt = sentAt
    }

    public var id: Int { seq }

    /// The server's limit; longer text is refused.
    public static let maxLength = 200
}

/// A room where two players gather before a game; see `ClientCommand.createRoom`.
public struct RoomState: Sendable, Hashable {
    public struct Member: Sendable, Hashable {
        public var name: String
        public var isReady: Bool
        public var isYou: Bool
        public var isHost: Bool
        public var isConnected: Bool

        public init(
            name: String, isReady: Bool = false, isYou: Bool = false, isHost: Bool = false, isConnected: Bool = true
        ) {
            self.name = name
            self.isReady = isReady
            self.isYou = isYou
            self.isHost = isHost
            self.isConnected = isConnected
        }
    }

    public var code: String
    public var timeControl: TimeControl
    /// Host first; at most two.
    public var members: [Member]
    /// The game in progress, if any.
    public var gameID: String?
    /// This player's side in the next game; nil when random.
    public var yourNextColor: PieceColor?
    /// Recent chat. Only sent on create, join and resume: empty in other
    /// updates, where the client keeps what it has.
    public var chat: [ChatMessage]
    public var gamesPlayed: Int
    /// Both players are ready: the game starts in this long unless someone
    /// cancels. Relative, so a wrong clock on the device does not matter.
    public var startsIn: Duration?

    public init(
        code: String, timeControl: TimeControl, members: [Member], gameID: String? = nil,
        yourNextColor: PieceColor? = nil, chat: [ChatMessage] = [], gamesPlayed: Int = 0,
        startsIn: Duration? = nil
    ) {
        self.code = code
        self.timeControl = timeControl
        self.members = members
        self.gameID = gameID
        self.yourNextColor = yourNextColor
        self.chat = chat
        self.gamesPlayed = gamesPlayed
        self.startsIn = startsIn
    }

    public var me: Member? { members.first(where: \.isYou) }
    public var opponent: Member? { members.first(where: { !$0.isYou }) }
}

/// Everything needed to show a game: sent when it starts and, as a snapshot,
/// after a resumed connection.
public struct GameState: Sendable, Hashable {
    public var id: String
    public var color: PieceColor
    public var opponent: String
    public var timeControl: TimeControl
    public var moves: [Move]
    public var position: Position
    public var clocks: Clocks
    public var drawOfferedBy: PieceColor?
    public var opponentConnected: Bool
    /// While the opponent is away: how long it has to come back.
    public var opponentReconnectWithin: Duration
    /// Oldest first.
    public var chat: [ChatMessage]

    public init(
        id: String, color: PieceColor, opponent: String, timeControl: TimeControl,
        moves: [Move] = [], position: Position, clocks: Clocks,
        drawOfferedBy: PieceColor? = nil, opponentConnected: Bool = true,
        opponentReconnectWithin: Duration = .zero, chat: [ChatMessage] = []
    ) {
        self.id = id
        self.color = color
        self.opponent = opponent
        self.timeControl = timeControl
        self.moves = moves
        self.position = position
        self.clocks = clocks
        self.drawOfferedBy = drawOfferedBy
        self.opponentConnected = opponentConnected
        self.opponentReconnectWithin = opponentReconnectWithin
        self.chat = chat
    }
}

/// Commands the client can send.
public enum ClientCommand: Sendable, Hashable {
    /// A nil name plays anonymously; the server picks the name.
    /// `language` is the interface language ("ru", "en"); see `Hello.language`.
    /// `accessToken` comes from the auth service; with it, the server knows
    /// the player by account and ignores `name`.
    case hello(name: String?, resumeToken: String?, language: String? = nil, accessToken: String? = nil)
    /// `side` is the preferred color, nil for either.
    case findGame(TimeControl, side: PieceColor?)
    case cancelSearch
    case makeMove(gameID: String, ply: Int, move: Move)
    case resign(gameID: String)
    /// Offers a draw, or accepts the opponent's pending offer.
    case offerDraw(gameID: String)
    case declineDraw(gameID: String)
    case sendChat(gameID: String, text: String)
    /// Opens a room. `side` is this player's color in the first game, nil for random.
    case createRoom(TimeControl, side: PieceColor?)
    case joinRoom(code: String)
    case leaveRoom
    /// Both players ready starts the game.
    case setReady(Bool)
    case sendRoomChat(code: String, text: String)
}

/// Decoded server messages.
public enum ServerEvent: Sendable, Hashable {
    /// `name` is how the server shows this player, e.g. "anonim3f9a1c".
    case welcome(playerID: String, name: String, resumeToken: String, resumed: Bool)
    case searchStarted(TimeControl)
    case searchCancelled
    case gameStarted(GameState)
    /// Replaces the client's state after a resumed connection.
    case snapshot(GameState)
    /// Sent for both players' moves; `position` is the server's position after it.
    case moveMade(gameID: String, ply: Int, move: Move, position: Position, clocks: Clocks)
    case moveRejected(gameID: String, ply: Int, reason: String, position: Position)
    /// May arrive twice after a reconnect; ignore it if the game is already over.
    case gameOver(gameID: String, result: GameResult, termination: Termination, clocks: Clocks?)
    case drawOffer(gameID: String, offeredBy: PieceColor?)
    case opponentStatus(gameID: String, connected: Bool, reconnectWithin: Duration)
    case chat(gameID: String, ChatMessage)
    case roomChat(code: String, ChatMessage)
    /// Sent on every change of the room.
    case roomState(RoomState)
    /// The player is no longer in the room: it left, or did not come back in time.
    case roomLeft(code: String)
    case serverError(code: String, message: String)
}

public enum ProtocolError: Error, Sendable, Equatable {
    case emptyMessage
    case badPosition(String)
    case badMove(String)
    case badColor
}

// MARK: - Wire mapping

extension ClientCommand {
    public var message: Chess_V1_ClientMessage {
        var m = Chess_V1_ClientMessage()
        switch self {
        case .hello(let name, let token, let language, let accessToken):
            m.hello = .with {
                $0.protocolVersion = protocolVersion
                $0.name = name ?? ""
                $0.anonymous = name == nil
                $0.resumeToken = token ?? ""
                $0.language = language ?? ""
                $0.accessToken = accessToken ?? ""
            }
        case .findGame(let tc, let side):
            m.findGame = .with {
                $0.timeControl = tc.wire
                $0.color = side.map { $0 == .white ? .white : .black } ?? .unspecified
            }
        case .cancelSearch:
            m.cancelSearch = Chess_V1_CancelSearch()
        case .makeMove(let gameID, let ply, let move):
            m.makeMove = .with {
                $0.gameID = gameID
                $0.ply = UInt32(ply)
                $0.uci = move.uci
            }
        case .resign(let gameID):
            m.resign = .with { $0.gameID = gameID }
        case .offerDraw(let gameID):
            m.offerDraw = .with { $0.gameID = gameID }
        case .declineDraw(let gameID):
            m.declineDraw = .with { $0.gameID = gameID }
        case .sendChat(let gameID, let text):
            m.sendChat = .with {
                $0.gameID = gameID
                $0.text = text
            }
        case .createRoom(let tc, let side):
            m.createRoom = .with {
                $0.timeControl = tc.wire
                $0.color = side.map { $0 == .white ? .white : .black } ?? .unspecified
            }
        case .joinRoom(let code):
            m.joinRoom = .with { $0.code = code }
        case .leaveRoom:
            m.leaveRoom = Chess_V1_LeaveRoom()
        case .setReady(let ready):
            m.setReady = .with { $0.ready = ready }
        case .sendRoomChat(let code, let text):
            m.sendChat = .with {
                $0.roomCode = code
                $0.text = text
            }
        }
        return m
    }
}

extension ServerEvent {
    public init(_ message: Chess_V1_ServerMessage) throws(ProtocolError) {
        switch message.payload {
        case .welcome(let w):
            self = .welcome(playerID: w.playerID, name: w.name, resumeToken: w.resumeToken, resumed: w.resumed)
        case .searchStarted(let s):
            self = .searchStarted(TimeControl(s.timeControl))
        case .searchCancelled:
            self = .searchCancelled
        case .gameStarted(let g):
            guard let color = PieceColor(g.color) else { throw .badColor }
            self = .gameStarted(
                GameState(
                    id: g.gameID, color: color, opponent: g.opponentName,
                    timeControl: TimeControl(g.timeControl),
                    position: try parse(fen: g.fen), clocks: Clocks(g.clocks)
                ))
        case .snapshot(let s):
            guard let color = PieceColor(s.color) else { throw .badColor }
            var moves: [Move] = []
            for uci in s.moves {
                guard let move = Move(uci: uci) else { throw .badMove(uci) }
                moves.append(move)
            }
            var chat: [ChatMessage] = []
            for line in s.chat {
                chat.append(try ChatMessage(line))
            }
            self = .snapshot(
                GameState(
                    id: s.gameID, color: color, opponent: s.opponentName,
                    timeControl: TimeControl(s.timeControl), moves: moves,
                    position: try parse(fen: s.fen), clocks: Clocks(s.clocks),
                    drawOfferedBy: PieceColor(s.drawOfferedBy),
                    opponentConnected: s.opponentConnected,
                    opponentReconnectWithin: .milliseconds(s.opponentReconnectMs),
                    chat: chat
                ))
        case .moveMade(let m):
            guard let move = Move(uci: m.uci) else { throw .badMove(m.uci) }
            self = .moveMade(
                gameID: m.gameID, ply: Int(m.ply), move: move,
                position: try parse(fen: m.fen), clocks: Clocks(m.clocks)
            )
        case .moveRejected(let r):
            self = .moveRejected(gameID: r.gameID, ply: Int(r.ply), reason: r.reason, position: try parse(fen: r.fen))
        case .gameOver(let o):
            self = .gameOver(
                gameID: o.gameID, result: GameResult(o.result), termination: Termination(o.termination),
                clocks: o.hasClocks ? Clocks(o.clocks) : nil
            )
        case .drawOffer(let d):
            self = .drawOffer(gameID: d.gameID, offeredBy: PieceColor(d.offeredBy))
        case .opponentStatus(let s):
            self = .opponentStatus(
                gameID: s.gameID, connected: s.connected, reconnectWithin: .milliseconds(s.reconnectMs))
        case .chatMessage(let c):
            if c.roomCode.isEmpty {
                self = .chat(gameID: c.gameID, try ChatMessage(c))
            } else {
                self = .roomChat(code: c.roomCode, try ChatMessage(c))
            }
        case .roomState(let r):
            var chat: [ChatMessage] = []
            for line in r.chat {
                chat.append(try ChatMessage(line))
            }
            self = .roomState(
                RoomState(
                    code: r.code, timeControl: TimeControl(r.timeControl),
                    members: r.members.map {
                        .init(
                            name: $0.name, isReady: $0.ready, isYou: $0.you, isHost: $0.host, isConnected: $0.connected)
                    },
                    gameID: r.gameID.isEmpty ? nil : r.gameID,
                    yourNextColor: PieceColor(r.yourNextColor),
                    chat: chat, gamesPlayed: Int(r.gamesPlayed),
                    startsIn: r.startsInMs > 0 ? .milliseconds(r.startsInMs) : nil
                ))
        case .roomLeft(let r):
            self = .roomLeft(code: r.code)
        case .error(let e):
            self = .serverError(code: e.code, message: e.message)
        case nil:
            throw .emptyMessage
        }
    }
}

private func parse(fen: String) throws(ProtocolError) -> Position {
    do {
        return try Position(fen: fen)
    } catch {
        throw .badPosition(fen)
    }
}

extension PieceColor {
    /// nil for COLOR_UNSPECIFIED.
    init?(_ wire: Chess_V1_Color) {
        switch wire {
        case .white: self = .white
        case .black: self = .black
        default: return nil
        }
    }
}

extension ChatMessage {
    init(_ wire: Chess_V1_ChatMessage) throws(ProtocolError) {
        let from = PieceColor(wire.from)
        // Game chat always names the side.
        if wire.roomCode.isEmpty, from == nil { throw .badColor }
        self.init(
            seq: Int(wire.seq), from: from, author: wire.author, isMine: wire.yours, text: wire.text,
            sentAt: Date(timeIntervalSince1970: Double(wire.sentAtMs) / 1000)
        )
    }
}

extension Clocks {
    init(_ wire: Chess_V1_Clocks) {
        white = .milliseconds(wire.whiteMs)
        black = .milliseconds(wire.blackMs)
    }
}

extension TimeControl {
    init(_ wire: Chess_V1_TimeControl) {
        initialSeconds = Int(wire.initialSeconds)
        incrementSeconds = Int(wire.incrementSeconds)
    }

    var wire: Chess_V1_TimeControl {
        .with {
            $0.initialSeconds = UInt32(initialSeconds)
            $0.incrementSeconds = UInt32(incrementSeconds)
        }
    }
}

extension GameResult {
    init(_ wire: Chess_V1_Result) {
        switch wire {
        case .whiteWins: self = .whiteWins
        case .blackWins: self = .blackWins
        case .draw: self = .draw
        default: self = .unknown
        }
    }
}

extension Termination {
    init(_ wire: Chess_V1_Termination) {
        switch wire {
        case .checkmate: self = .checkmate
        case .stalemate: self = .stalemate
        case .insufficientMaterial: self = .insufficientMaterial
        case .threefoldRepetition: self = .threefoldRepetition
        case .fiftyMoveRule: self = .fiftyMoveRule
        case .resignation: self = .resignation
        case .abandonment: self = .abandonment
        case .timeout: self = .timeout
        case .drawAgreement: self = .drawAgreement
        default: self = .unknown
        }
    }
}
