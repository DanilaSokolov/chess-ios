import ChessNet
import Foundation

/// A room the player sits in, with its chat: room updates other than join
/// and resume carry no chat, so the client keeps the history itself.
public struct RoomSession: Hashable, Sendable {
    public var state: RoomState
    public var chat: [ChatMessage]
    /// When the game starts, while both players are ready and counting down.
    public var countdownEnds: Date?

    public init(_ state: RoomState) {
        self.state = state
        chat = state.chat
    }

    public var code: String { state.code }
}
