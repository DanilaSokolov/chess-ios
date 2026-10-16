import ChessNet
import Foundation

/// What to tell the player about a refusal from the server, and where.
/// Why the server refused a move, in the player's language. The server sends
/// a fixed English phrase per reason (see game.Room.reject), which works as a code.
public func moveRejectionText(_ reason: String) -> String {
    switch reason {
    case "illegal move": String(localized: "That move is not allowed", bundle: .module)
    case "not your turn": String(localized: "It is not your move", bundle: .module)
    case "out of sequence": String(localized: "The move arrived out of order", bundle: .module)
    // A reason added to the server later. Its English text is not shown: the
    // player may not read English, and the board already says enough.
    default: String(localized: "The server did not accept the move", bundle: .module)
    }
}

public enum ServerErrorText: Equatable, Sendable {
    /// Shown on the current screen.
    case general(String)
    /// Shown in the chat, next to the message that was refused.
    case chat(String)
    /// Not worth showing: a harmless race that the next update fixes.
    case ignore

    public init(code: String, message: String) {
        self =
            switch code {
            case "room_not_found": .general(String(localized: "There is no room with this code", bundle: .module))
            case "room_full": .general(String(localized: "This room already has two players", bundle: .module))
            case "room_rate_limited":
                .general(String(localized: "Too many attempts — please wait a little", bundle: .module))
            case "already_in_room": .general(String(localized: "Leave your room first", bundle: .module))
            case "already_playing": .general(String(localized: "Finish your current game first", bundle: .module))
            case "invalid_time_control":
                .general(String(localized: "This time control is not available", bundle: .module))
            case "unsupported_protocol":
                .general(String(localized: "Please update the app: the server speaks a newer version", bundle: .module))
            case "chat_empty": .chat(String(localized: "The message is empty", bundle: .module))
            case "chat_too_long":
                .chat(String(localized: "At most \(ChatMessage.maxLength) characters", bundle: .module))
            case "chat_rate_limited": .chat(String(localized: "Too fast — wait a couple of seconds", bundle: .module))
            // A command sent just before the game ended or started, or the room
            // went away, races with the update that already fixes the screen.
            case "no_such_game", "game_in_progress", "not_in_room": .ignore
            // The access token was refused; the app renews it and reconnects by itself.
            case "invalid_token": .ignore
            // The server did not understand us: the app is older or newer than it.
            case "unexpected_hello", "unknown_message":
                .general(
                    String(
                        localized: "The app and the server do not understand each other — please update the app",
                        bundle: .module))
            // A code added to the server later. Its message is in English, so show
            // a phrase of our own; the code helps when the player reports it.
            default: .general(String(localized: "The server refused the request (\(code))", bundle: .module))
            }
    }
}
