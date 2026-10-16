import ChessClient
import ChessCore
import ChessNet
import SwiftUI

/// Opens the chat: the newest message as a preview and an unread badge.
struct ChatButton: View {
    @Environment(GameModel.self) private var model

    var body: some View {
        Button {
            model.isChatOpen = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                if let last = model.state.chatMessages.last {
                    // As Telegram previews a group chat: who wrote it, then what.
                    Group {
                        if last.isMine {
                            Text("You: \(last.text)")
                        } else if last.author.isEmpty {
                            Text(verbatim: last.text)
                        } else {
                            Text(verbatim: "\(last.author): \(last.text)")
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Chat").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.state.chat.unread > 0 {
                    Text(verbatim: "\(model.state.chat.unread)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                }
            }
            .font(.subheadline)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.state.chat.unread > 0 ? "Chat, unread: \(model.state.chat.unread)" : "Chat")
    }
}

/// The chat in a sheet, opened from the game screen.
struct ChatView: View {
    @Environment(GameModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatPanel()
                .navigationTitle(model.state.chatPartner ?? String(localized: "Chat"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        MuteButton()
                    }
                }
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(macOS)
            .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

/// Hides or shows the opponent's messages on this device.
struct MuteButton: View {
    @Environment(GameModel.self) private var model

    var body: some View {
        let muted = model.state.chat.isOpponentMuted
        Button {
            model.setOpponentMuted(!muted)
        } label: {
            Label(
                muted ? "Show opponent" : "Hide opponent",
                systemImage: muted ? "speaker.wave.2" : "speaker.slash")
        }
        .help(muted ? "Show the opponent's messages" : "Hide the opponent's messages")
    }
}

/// Messages and the composer for the current chat. Used in the sheet and
/// inline: in the room, and beside the board on a wide game screen.
struct ChatPanel: View {
    @Environment(GameModel.self) private var model
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messages
            Divider()
            composer
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.state.chatMessages.isEmpty {
                        Text(
                            model.state.chat.isOpponentMuted ? "The opponent's messages are hidden" : "No messages yet"
                        )
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                    }
                    ForEach(ChatLayout.rows(model.state.chatMessages)) { row in
                        Bubble(row: row)
                            .id(row.message.seq)
                            // Tight within a group, wider between groups, as in Telegram.
                            .padding(.bottom, row.isLastInGroup ? 10 : 2)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.state.chatMessages.last?.seq) { _, seq in
                guard let seq else { return }
                withAnimation { proxy.scrollTo(seq, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.state.chat.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if model.state.isChatClosed {
                Text("The game is over, the chat is closed").font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Message", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .submitLabel(.send)
                        #endif
                        .focused($isFocused)
                        .onSubmit(send)
                        .onChange(of: draft) {
                            if draft.count > ChatMessage.maxLength {
                                draft = String(draft.prefix(ChatMessage.maxLength))
                            }
                        }
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
                if model.connection != .online {
                    Text("No connection to the server").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var canSend: Bool {
        model.connection == .online && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        isFocused = true
        Task { await model.sendChat(text) }
    }
}

/// One message, laid out as in Telegram's group chats: others' on the left
/// with the author's name (on the first of a group) and avatar (beside the
/// last), one's own on the right; the time inside the bubble, bottom right.
private struct Bubble: View {
    let row: ChatRow

    private var message: ChatMessage { row.message }

    var body: some View {
        let isMine = message.isMine
        HStack(alignment: .bottom, spacing: 8) {
            if isMine {
                Spacer(minLength: 48)
            } else {
                // The avatar's place is kept on every row, so a group's bubbles line up.
                Group {
                    if row.showsAvatar {
                        Avatar(name: message.author)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                if row.showsName && !message.author.isEmpty {
                    Text(verbatim: message.author)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(nameColor(message.author))
                        .lineLimit(1)
                }
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(verbatim: message.text)
                        .textSelection(.enabled)
                    Text(message.sentAt, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(isMine ? Color.white.opacity(0.75) : Color.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isMine ? Color.white : Color.primary)
            .background(isMine ? Color.accentColor : Color.secondary.opacity(0.15), in: bubbleShape)
            if !isMine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Rounded, with the corner by the avatar (or by the edge, for one's own)
    /// tucked in on a group's last bubble: Telegram's "tail" without drawing one.
    private var bubbleShape: UnevenRoundedRectangle {
        let r: CGFloat = 16
        let tail: CGFloat = row.isLastInGroup ? 4 : r
        return message.isMine
            ? UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: tail, topTrailingRadius: r)
            : UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: tail, bottomTrailingRadius: r, topTrailingRadius: r)
    }

    private var accessibilityText: Text {
        let time = message.sentAt.formatted(date: .omitted, time: .shortened)
        return message.isMine
            ? Text("You: \(message.text)") + Text(verbatim: ", \(time)")
            : Text(verbatim: "\(message.author): \(message.text), \(time)")
    }
}

/// A round avatar with the author's initials, in the author's colour.
private struct Avatar: View {
    let name: String

    var body: some View {
        Text(verbatim: ChatLayout.initials(of: name))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(nameColor(name).gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The author's colour: one of seven, the same for a name everywhere.
private func nameColor(_ name: String) -> Color {
    let palette: [Color] = [.red, .orange, .purple, .green, .teal, .blue, .pink]
    return palette[ChatLayout.colorIndex(for: name) % palette.count]
}
