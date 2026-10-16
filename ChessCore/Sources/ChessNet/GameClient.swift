import ChessProto
import Foundation
internal import SwiftProtobuf

public enum ClientEvent: Sendable {
    case server(ServerEvent)
    /// The connection ended. `reason` is nil after `disconnect()`.
    case disconnected(reason: DisconnectReason?)
}

/// Why a connection ended. The network layer speaks no language: it says
/// what happened, and the app decides how to tell the player.
public enum DisconnectReason: Sendable, Equatable {
    /// The network failed or the server closed the socket. The text comes from
    /// the system and is already in the player's language.
    case network(String)
    /// The server sent a message this client cannot read: the two speak
    /// different versions of the protocol, or one of them has a bug.
    case unreadableMessage
}

/// One WebSocket connection to the game server.
///
/// Create it, iterate `events`, call `connect()`. Every binary frame is one
/// protobuf envelope (`ClientMessage` out, `ServerMessage` in). A client is
/// single-use: to reconnect after `.disconnected`, create a new one with the
/// resume token from `.welcome` and the server continues the game.
public actor GameClient {
    public nonisolated let events: AsyncStream<ClientEvent>

    private let continuation: AsyncStream<ClientEvent>.Continuation
    private let task: URLSessionWebSocketTask
    private let playerName: String?
    private let resumeToken: String?
    private let language: String?
    private let accessToken: String?
    private var receiver: Task<Void, Never>?
    private var finished = false

    /// A nil `playerName` plays anonymously. `language` is sent in Hello so the
    /// server knows which language the player reads. `accessToken` signs in
    /// with an account from the auth service.
    public init(
        url: URL, playerName: String?, resumeToken: String? = nil, language: String? = nil,
        accessToken: String? = nil, session: URLSession = .shared
    ) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        task = session.webSocketTask(with: url)
        self.playerName = playerName
        self.resumeToken = resumeToken
        self.language = language
        self.accessToken = accessToken
    }

    public func connect() async {
        task.resume()
        do {
            try await send(
                .hello(name: playerName, resumeToken: resumeToken, language: language, accessToken: accessToken))
        } catch {
            finish(reason: .network(error.localizedDescription))
            return
        }
        receiver = Task { await self.receiveLoop() }
    }

    public func send(_ command: ClientCommand) async throws {
        let data: Data = try command.message.serializedBytes()
        try await task.send(.data(data))
    }

    public func disconnect() {
        task.cancel(with: .normalClosure, reason: nil)
        finish(reason: nil)
    }

    private func receiveLoop() async {
        while !finished {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                finish(reason: .network(error.localizedDescription))
                return
            }
            guard case .data(let data) = frame else { continue }
            do {
                let message = try Chess_V1_ServerMessage(serializedBytes: data)
                continuation.yield(.server(try ServerEvent(message)))
            } catch {
                // A message we cannot understand is a protocol bug; drop the connection.
                task.cancel(with: .protocolError, reason: nil)
                finish(reason: .unreadableMessage)
                return
            }
        }
    }

    private func finish(reason: DisconnectReason?) {
        guard !finished else { return }
        finished = true
        receiver?.cancel()
        continuation.yield(.disconnected(reason: reason))
        continuation.finish()
    }
}
