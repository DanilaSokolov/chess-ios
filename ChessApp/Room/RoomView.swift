import ChessClient
import ChessCore
import ChessNet
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// A room between games: the code to pass on, who is in, readiness and chat.
///
/// Upright, one column: the room on top, the chat filling the rest. Where the
/// height is compact (a phone on its side, the outer display of iPhone Duo on
/// its side: about 400 pt) that column would not fit, so the room scrolls on
/// the left and the chat takes the right.
struct RoomView: View {
    @Environment(GameModel.self) private var model
    #if os(iOS)
        @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    /// How wide the single column gets on a wide screen (iPad, the inner display
    /// of iPhone Duo, a Mac window). Cards and a chat stretched to a full iPad
    /// width only get harder to read, so the column stays phone-sized, centred.
    /// Scaled with Dynamic Type, as UIKit's readable width is: larger text, a
    /// wider column, the same words per line.
    @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 520
    let room: RoomSession

    private var state: RoomState { room.state }

    /// Too short for the room above the chat: put them side by side.
    private var isHeightCompact: Bool {
        #if os(iOS)
            return verticalSizeClass == .compact
        #else
            // No size classes on the Mac, and no need: a window cannot be made
            // shorter than this column, as its minimum size follows the content.
            return false
        #endif
    }

    var body: some View {
        let isSideBySide = isHeightCompact
        // `AnyLayout`, not `if` between an HStack and a VStack: the chat keeps its
        // identity when the phone turns, so a half-typed message survives.
        let layout =
            isSideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 14))
        layout {
            if isSideBySide {
                ScrollView { info }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                info
            }
            ChatPanel()
                // Side by side the chat has the full height, which with the
                // keyboard up is less than 180 pt: no minimum there.
                .frame(minHeight: isSideBySide ? nil : 180)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding()
        .frame(maxWidth: isSideBySide ? CGFloat.infinity : readableWidth)
        // Centred in the whole screen; and the countdown below covers all of it,
        // not just the column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let ends = room.countdownEnds {
                CountdownOverlay(ends: ends) {
                    Task { await model.setReady(false) }
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: room.countdownEnds)
    }

    /// Everything but the chat: the code, who is in, errors and the buttons.
    private var info: some View {
        VStack(spacing: 14) {
            codeCard
            if case .reconnecting(let attempt) = model.connection {
                Label("Reconnecting… (attempt \(attempt))", systemImage: "wifi.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            members
            if let error = model.state.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            actions
        }
    }

    private var codeCard: some View {
        VStack(spacing: 6) {
            Text("Room code").font(.caption).foregroundStyle(.secondary)
            Text(state.code)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .tracking(6)
                .textSelection(.enabled)
                .accessibilityLabel("Room code \(state.code.map(String.init).joined(separator: " "))")
            HStack {
                Button("Copy", systemImage: "doc.on.doc") { copy(state.code) }
                ShareLink(item: String(localized: "Fancy a game of chess? Room code: \(state.code)")) {
                    Label("Send", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text(details).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var details: String {
        let side =
            switch state.yourNextColor {
            case .white: String(localized: "you play White")
            case .black: String(localized: "you play Black")
            case nil: String(localized: "random colour")
            }
        let played = state.gamesPlayed > 0 ? String(localized: " · played: \(state.gamesPlayed)") : ""
        return "\(state.timeControl) · \(side)\(played)"
    }

    private var members: some View {
        VStack(spacing: 8) {
            // Names may repeat, positions do not.
            ForEach(Array(state.members.enumerated()), id: \.offset) { _, member in
                MemberRow(member: member)
            }
            if state.members.count < 2 {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for an opponent — send them the code")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
            }
        }
    }

    private var actions: some View {
        let isReady = state.me?.isReady ?? false
        return HStack {
            Button {
                Task { await model.setReady(!isReady) }
            } label: {
                Text(isReady ? "Not ready" : "Ready").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isReady ? .gray : .accentColor)
            .disabled(model.connection != .online)

            Button("Leave", role: .destructive) {
                Task { await model.leaveRoom() }
            }
            .buttonStyle(.bordered)
            .disabled(model.connection != .online)
        }
        .controlSize(.large)
    }

    private func copy(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

private struct MemberRow: View {
    let member: RoomState.Member

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: member.isReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(member.isReady ? Color.green : Color.secondary)
            Text(member.name).fontWeight(member.isYou ? .semibold : .regular)
            if member.isYou {
                Text("you").font(.caption).foregroundStyle(.secondary)
            }
            if member.isHost {
                Image(systemName: "crown.fill").font(.caption).foregroundStyle(.yellow)
                    .accessibilityLabel("room host")
            }
            Spacer()
            if !member.isConnected {
                Text("offline").font(.caption).foregroundStyle(.orange)
            } else {
                Text(member.isReady ? "ready" : "not ready").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
