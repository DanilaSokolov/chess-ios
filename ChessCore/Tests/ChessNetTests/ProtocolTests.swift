import ChessCore
import ChessProto
import Foundation
import SwiftProtobuf
import Testing

@testable import ChessNet

@Test func makeMoveEncodesUCIAndPly() throws {
    let command = ClientCommand.makeMove(gameID: "g1", ply: 3, move: Move(uci: "e7e8q")!)
    let data: Data = try command.message.serializedBytes()
    let decoded = try Chess_V1_ClientMessage(serializedBytes: data)
    #expect(decoded.makeMove.gameID == "g1")
    #expect(decoded.makeMove.ply == 3)
    #expect(decoded.makeMove.uci == "e7e8q")
}

@Test func helloCarriesProtocolVersionAndToken() {
    let hello = ClientCommand.hello(name: "ann", resumeToken: "secret").message.hello
    #expect(hello.protocolVersion == protocolVersion)
    #expect(hello.resumeToken == "secret")
    #expect(ClientCommand.hello(name: "ann", resumeToken: nil).message.hello.resumeToken == "")
    #expect(!hello.anonymous)
    #expect(hello.language == "", "no language unless the app says")
    #expect(ClientCommand.hello(name: nil, resumeToken: nil, language: "ru").message.hello.language == "ru")
}

@Test func helloCarriesAccessToken() {
    #expect(ClientCommand.hello(name: nil, resumeToken: nil).message.hello.accessToken == "", "a guest sends none")
    let hello = ClientCommand.hello(name: nil, resumeToken: "r", accessToken: "header.claims.signature").message.hello
    #expect(hello.accessToken == "header.claims.signature")
}

@Test func anonymousHello() {
    let hello = ClientCommand.hello(name: nil, resumeToken: nil).message.hello
    #expect(hello.anonymous)
    #expect(hello.name == "")
}

@Test func welcomeCarriesName() throws {
    var message = Chess_V1_ServerMessage()
    message.welcome = .with {
        $0.playerID = "3f9a1c0011223344"
        $0.name = "anonim3f9a1c"
        $0.resumeToken = "t"
    }
    #expect(
        try ServerEvent(message)
            == .welcome(playerID: "3f9a1c0011223344", name: "anonim3f9a1c", resumeToken: "t", resumed: false))
}

@Test func findGameCarriesSide() {
    let tc = TimeControl(minutes: 3, increment: 2)
    #expect(ClientCommand.findGame(tc, side: .black).message.findGame.color == .black)
    #expect(ClientCommand.findGame(tc, side: .white).message.findGame.color == .white)
    #expect(ClientCommand.findGame(tc, side: nil).message.findGame.color == .unspecified)
}

@Test func drawCommands() {
    #expect(ClientCommand.offerDraw(gameID: "g").message.offerDraw.gameID == "g")
    #expect(ClientCommand.declineDraw(gameID: "g").message.declineDraw.gameID == "g")
}

@Test func decodesGameStarted() throws {
    var message = Chess_V1_ServerMessage()
    message.gameStarted = .with {
        $0.gameID = "g1"
        $0.color = .black
        $0.opponentName = "bob"
        $0.fen = Position.startingFEN
        $0.timeControl = .with {
            $0.initialSeconds = 180
            $0.incrementSeconds = 2
        }
        $0.clocks = .with {
            $0.whiteMs = 180_000
            $0.blackMs = 180_000
        }
    }
    let event = try ServerEvent(message)
    #expect(
        event
            == .gameStarted(
                GameState(
                    id: "g1", color: .black, opponent: "bob", timeControl: TimeControl(minutes: 3, increment: 2),
                    position: .starting, clocks: Clocks(white: .seconds(180), black: .seconds(180))
                )))
}

@Test func decodesSnapshot() throws {
    var message = Chess_V1_ServerMessage()
    message.snapshot = .with {
        $0.gameID = "g1"
        $0.color = .white
        $0.opponentName = "bob"
        $0.moves = ["e2e4", "e7e5"]
        $0.fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"
        $0.clocks = .with {
            $0.whiteMs = 1_500
            $0.blackMs = 2_000
        }
        $0.drawOfferedBy = .black
        $0.opponentConnected = false
        $0.opponentReconnectMs = 42_000
    }
    guard case .snapshot(let state) = try ServerEvent(message) else {
        Issue.record("expected a snapshot")
        return
    }
    #expect(state.moves == [Move(uci: "e2e4")!, Move(uci: "e7e5")!])
    #expect(state.clocks[.white] == .milliseconds(1_500))
    #expect(state.drawOfferedBy == .black)
    #expect(!state.opponentConnected)
    #expect(state.opponentReconnectWithin == .seconds(42))
}

@Test func drawOfferWithoutColorMeansWithdrawn() throws {
    var message = Chess_V1_ServerMessage()
    message.drawOffer = .with { $0.gameID = "g1" }
    #expect(try ServerEvent(message) == .drawOffer(gameID: "g1", offeredBy: nil))
}

@Test func rejectsBadServerData() {
    var noColor = Chess_V1_ServerMessage()
    noColor.gameStarted = .with { $0.fen = Position.startingFEN }
    #expect(throws: ProtocolError.badColor) { try ServerEvent(noColor) }

    var badFEN = Chess_V1_ServerMessage()
    badFEN.moveMade = .with {
        $0.uci = "e2e4"
        $0.fen = "nonsense"
    }
    #expect(throws: ProtocolError.badPosition("nonsense")) { try ServerEvent(badFEN) }

    var badMove = Chess_V1_ServerMessage()
    badMove.snapshot = .with {
        $0.color = .white
        $0.moves = ["e2"]
    }
    #expect(throws: ProtocolError.badMove("e2")) { try ServerEvent(badMove) }

    #expect(throws: ProtocolError.emptyMessage) { try ServerEvent(Chess_V1_ServerMessage()) }
}

@Test func endpointsFromAddresses() throws {
    #expect(
        GRPCEndpoint(url: URL(string: "ws://localhost:8080/ws")!)
            == GRPCEndpoint(host: "localhost", port: 8080, usesTLS: false))
    #expect(
        GRPCEndpoint(url: URL(string: "wss://chess.example.com/ws")!)
            == GRPCEndpoint(host: "chess.example.com", port: 443, usesTLS: true))
    #expect(
        GRPCEndpoint(url: URL(string: "http://192.168.1.5:8081")!)
            == GRPCEndpoint(host: "192.168.1.5", port: 8081, usesTLS: false))
    #expect(GRPCEndpoint(url: URL(string: "ftp://example.com")!) == nil)
}

@Test func bootstrapFromTheWire() {
    let wire = Chess_V1_BootstrapResponse.with {
        $0.status = .outdated
        $0.minVersion = "0.1.0"
        $0.latestVersion = "0.2.0"
        $0.timeControls = [
            .with {
                $0.initialSeconds = 180
                $0.incrementSeconds = 2
            }
        ]
        $0.authURL = "http://localhost:8081"
    }
    let b = Bootstrap(wire)
    #expect(b.client.status == .outdated)
    #expect(b.client.updateURL == nil, "an empty string is no address")
    #expect(b.lobbyTimeControls == [TimeControl(minutes: 3, increment: 2)])
    #expect(b.auth?.url.absoluteString == "http://localhost:8081")
    // A status this app does not know yet still lets people play.
    #expect(Bootstrap(.with { $0.status = .UNRECOGNIZED(9) }).client.status == .outdated)
}

@Test func sendChatEncodesText() {
    let chat = ClientCommand.sendChat(gameID: "g", text: "удачи").message.sendChat
    #expect(chat.gameID == "g")
    #expect(chat.text == "удачи")
}

@Test func decodesChatMessage() throws {
    var message = Chess_V1_ServerMessage()
    message.chatMessage = .with {
        $0.gameID = "g"
        $0.seq = 7
        $0.from = .white
        $0.text = "gg"
        $0.sentAtMs = 1_700_000_000_500
        $0.author = "ann"
        $0.yours = true
    }
    let expected = ChatMessage(
        seq: 7, from: .white, author: "ann", isMine: true, text: "gg",
        sentAt: Date(timeIntervalSince1970: 1_700_000_000.5)
    )
    #expect(try ServerEvent(message) == .chat(gameID: "g", expected))

    message.chatMessage.from = .unspecified
    #expect(throws: ProtocolError.badColor) { try ServerEvent(message) }
}

@Test func snapshotCarriesChat() throws {
    var message = Chess_V1_ServerMessage()
    message.snapshot = .with {
        $0.gameID = "g"
        $0.color = .white
        $0.fen = Position.startingFEN
        $0.chat = [
            .with {
                $0.seq = 1
                $0.from = .black
                $0.text = "hi"
            },
            .with {
                $0.seq = 2
                $0.from = .white
                $0.text = "hello"
            },
        ]
    }
    guard case .snapshot(let state) = try ServerEvent(message) else {
        Issue.record("expected a snapshot")
        return
    }
    #expect(state.chat.map(\.text) == ["hi", "hello"])
    #expect(state.chat.map(\.from) == [.black, .white])
}

@Test func roomCommands() {
    let create = ClientCommand.createRoom(TimeControl(minutes: 5, increment: 0), side: .black).message.createRoom
    #expect(create.timeControl.initialSeconds == 300)
    #expect(create.color == .black)
    #expect(ClientCommand.joinRoom(code: "K7Q2MX").message.joinRoom.code == "K7Q2MX")
    #expect(ClientCommand.setReady(true).message.setReady.ready)
    let chat = ClientCommand.sendRoomChat(code: "K7Q2MX", text: "gg").message.sendChat
    #expect(chat.roomCode == "K7Q2MX")
    #expect(chat.gameID.isEmpty)
    if case .leaveRoom? = ClientCommand.leaveRoom.message.payload {
    } else {
        Issue.record("expected LeaveRoom")
    }
}

@Test func decodesRoomState() throws {
    var message = Chess_V1_ServerMessage()
    message.roomState = .with {
        $0.code = "K7Q2MX"
        $0.timeControl = .with {
            $0.initialSeconds = 180
            $0.incrementSeconds = 2
        }
        $0.members = [
            .with {
                $0.name = "ann"
                $0.host = true
                $0.ready = true
                $0.connected = true
            },
            .with {
                $0.name = "bob"
                $0.you = true
                $0.connected = false
            },
        ]
        $0.yourNextColor = .white
        $0.gamesPlayed = 2
        $0.chat = [
            .with {
                $0.roomCode = "K7Q2MX"
                $0.seq = 1
                $0.author = "ann"
                $0.text = "hi"
            }
        ]
    }
    guard case .roomState(let room) = try ServerEvent(message) else {
        Issue.record("expected room state")
        return
    }
    #expect(room.code == "K7Q2MX")
    #expect(room.gameID == nil)
    #expect(room.yourNextColor == .white)
    #expect(room.me?.name == "bob")
    #expect(room.me?.isConnected == false)
    #expect(room.opponent?.isHost == true)
    #expect(room.opponent?.isReady == true)
    #expect(room.chat.map(\.author) == ["ann"])
    #expect(room.chat.first?.from == nil)
    #expect(room.gamesPlayed == 2)
    #expect(room.startsIn == nil, "no countdown unless the server sends one")

    message.roomState.startsInMs = 2_500
    guard case .roomState(let counting) = try ServerEvent(message) else { return }
    #expect(counting.startsIn == .milliseconds(2_500))
}

@Test func roomChatAndLeave() throws {
    var message = Chess_V1_ServerMessage()
    message.chatMessage = .with {
        $0.roomCode = "R"
        $0.seq = 3
        $0.author = "bob"
        $0.text = "gg"
    }
    guard case .roomChat(let code, let line) = try ServerEvent(message) else {
        Issue.record("expected room chat")
        return
    }
    #expect(code == "R")
    #expect(line.author == "bob")
    #expect(!line.isMine)

    message.roomLeft = .with { $0.code = "R" }
    #expect(try ServerEvent(message) == .roomLeft(code: "R"))
}
