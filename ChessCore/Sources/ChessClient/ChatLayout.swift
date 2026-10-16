import ChessNet
import Foundation

/// How chat messages are laid out, after Telegram's group chats: messages in
/// a row from the same author make a group. A group shows the author's name
/// on its first message and the author's avatar beside its last one, and its
/// bubbles sit closer together than bubbles of different groups.
public struct ChatRow: Identifiable, Sendable, Equatable {
    public var message: ChatMessage
    /// The first of its group: the name goes on top (for others' messages).
    public var isFirstInGroup: Bool
    /// The last of its group: the avatar goes beside it, and the gap after it is wider.
    public var isLastInGroup: Bool

    public var id: Int { message.seq }

    /// Others' messages carry a name and an avatar; one's own do not.
    public var showsName: Bool { isFirstInGroup && !message.isMine }
    public var showsAvatar: Bool { isLastInGroup && !message.isMine }
}

public enum ChatLayout {
    /// Messages further apart than this start a new group even from the same author.
    public static let groupGap: TimeInterval = 5 * 60

    public static func rows(_ messages: [ChatMessage]) -> [ChatRow] {
        messages.indices.map { i in
            let m = messages[i]
            return ChatRow(
                message: m,
                isFirstInGroup: i == 0 || !sameGroup(messages[i - 1], m),
                isLastInGroup: i == messages.count - 1 || !sameGroup(m, messages[i + 1]))
        }
    }

    private static func sameGroup(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        a.isMine == b.isMine && a.author == b.author && b.sentAt.timeIntervalSince(a.sentAt) < groupGap
    }

    /// The number of colours names are drawn in (Telegram has 7).
    public static let nameColors = 7

    /// Which of the name colours an author gets: always the same for the same
    /// name, on every device and every launch. Swift's `hashValue` would not
    /// do: it is seeded randomly per launch. FNV-1a over the UTF-8 bytes is.
    public static func colorIndex(for name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(nameColors))
    }

    /// One or two letters for the avatar: the first letters of the first two
    /// words, as Telegram does with first and last names. "Bot 3+2" → "B3",
    /// "anonim3f9a1c" → "A".
    public static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}
