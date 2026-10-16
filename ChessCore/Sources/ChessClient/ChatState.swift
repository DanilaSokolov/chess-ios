import ChessNet

/// The client's side of the chat: what is unread, whether the opponent is
/// hidden, and why the last message was refused. The messages themselves
/// live with the game or room they belong to.
public struct ChatState: Hashable, Sendable {
    /// Opponent messages that arrived while the chat was not on screen.
    public private(set) var unread = 0
    /// Hides the opponent's messages on this device; the server still delivers them.
    public private(set) var isOpponentMuted = false
    /// Why the last chat message was refused.
    public var error: String?
    /// Opening the chat marks its messages as read.
    public var isOpen = false {
        didSet {
            if isOpen { unread = 0 }
        }
    }

    public init() {}

    public mutating func setOpponentMuted(_ muted: Bool) {
        isOpponentMuted = muted
        if muted { unread = 0 }
    }

    /// Everything is read, e.g. because the chat is now shown inline.
    public mutating func markRead() {
        unread = 0
    }

    /// Counts opponent messages newer than `seq` as unread, unless the player
    /// can see them (`visible`: the chat is open or shown inline) or the
    /// opponent is muted.
    mutating func count(_ messages: [ChatMessage], after seq: Int, visible: Bool) {
        guard !isOpen, !visible, !isOpponentMuted else { return }
        unread += messages.filter { $0.seq > seq && !$0.isMine }.count
    }
}
