import SwiftUI

/// "3, 2, 1, the game has begun" over the room while both players are ready.
/// The end time comes from the server, so both players see the same count.
struct CountdownOverlay: View {
    @Environment(\.screenTransition) private var transition
    let ends: Date
    /// Unreadies the player, which cancels the countdown for both.
    var onCancel: () -> Void = {}

    private static let labelLead: TimeInterval = 0.3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            // The game arrives about when our count reaches zero, give or take
            // network latency. Showing the label slightly early makes sure it is
            // on screen to travel into the game, instead of a "1" vanishing.
            let left = Int((ends.timeIntervalSince(context.date) - Self.labelLead).rounded(.up))
            VStack(spacing: 12) {
                if left > 0 {
                    Text("The game starts in")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(left)")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                } else {
                    // The same label the game shows; it travels there when the game opens.
                    GameStartedLabel()
                        .travels(as: .gameStarted, in: transition)
                }
            }
            .animation(.snappy, value: left)
            .sensoryFeedback(.impact(weight: .heavy), trigger: left)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Opaque, so the room does not show through while the game fades in.
            .background(.background)
            .accessibilityElement(children: .combine)
        }
    }
}

/// "The game has begun", briefly, over a game that a countdown led into.
/// A tap dismisses it early.
struct StartAnnouncement: View {
    @Environment(\.screenTransition) private var transition
    let ends: Date
    var onDismiss: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            if context.date < ends {
                GameStartedLabel()
                    .travels(as: .gameStarted, in: transition)
                    .contentShape(Capsule())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Dismiss")
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: ends)
    }
}

/// "The game has begun", looking the same on both screens so it can travel between them.
struct GameStartedLabel: View {
    var body: some View {
        Text("The game has begun!")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: Capsule())
    }
}

#Preview("Countdown") {
    CountdownOverlay(ends: .now.addingTimeInterval(3))
}
