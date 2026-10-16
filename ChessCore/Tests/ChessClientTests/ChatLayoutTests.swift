import ChessNet
import Foundation
import Testing

@testable import ChessClient

private let start = Date(timeIntervalSince1970: 1_000_000)

private func message(_ seq: Int, _ author: String, mine: Bool = false, at minutes: Double) -> ChatMessage {
    ChatMessage(seq: seq, author: author, isMine: mine, text: "m\(seq)", sentAt: start.addingTimeInterval(minutes * 60))
}

@Test func messagesInARowFromOneAuthorMakeAGroup() {
    let rows = ChatLayout.rows([
        message(1, "Bot", at: 0),
        message(2, "Bot", at: 1),
        message(3, "Bot", at: 2),
        message(4, "me", mine: true, at: 3),
        message(5, "Bot", at: 4),
    ])
    #expect(rows.map(\.isFirstInGroup) == [true, false, false, true, true])
    #expect(rows.map(\.isLastInGroup) == [false, false, true, true, true])
    // The name on the first of others' groups, the avatar beside the last; none on one's own.
    #expect(rows.map(\.showsName) == [true, false, false, false, true])
    #expect(rows.map(\.showsAvatar) == [false, false, true, false, true])
}

@Test func aPauseStartsANewGroup() {
    let rows = ChatLayout.rows([message(1, "Bot", at: 0), message(2, "Bot", at: 10)])
    #expect(rows.map(\.showsName) == [true, true], "10 minutes apart: the name again")
}

/// In a room both players are "others" to a third device's view of the past;
/// what matters is the author, not just the side.
@Test func differentAuthorsNeverShareAGroup() {
    let rows = ChatLayout.rows([message(1, "alice", at: 0), message(2, "bob", at: 0.5)])
    #expect(rows.map(\.showsName) == [true, true])
}

@Test func nameColorsAreStable() {
    // A fixed value, computed outside Swift: the same on every device and
    // launch. (A colour from hashValue would pass a same-launch check and
    // still change on the next launch.)
    #expect(ChatLayout.colorIndex(for: "Bot 3+2") == 4)
    #expect((0..<ChatLayout.nameColors).contains(ChatLayout.colorIndex(for: "anonim3f9a1c")))
    let spread = Set(
        ["alice", "bob", "carol", "dave", "erin", "frank", "Bot 3+2", "anonim7588e7"].map(ChatLayout.colorIndex))
    #expect(spread.count >= 4, "names spread over the colours")
}

@Test func initials() {
    #expect(ChatLayout.initials(of: "Bot 3+2") == "B3")
    #expect(ChatLayout.initials(of: "anonim3f9a1c") == "A")
    #expect(ChatLayout.initials(of: "Друг-бот") == "Д")
    #expect(ChatLayout.initials(of: "  ") == "?")
}
