import SwiftUI

/// Shown while `GameModel.start()` checks the version and reconnects. Kept
/// plain on purpose: it is on screen for a moment, not a show of its own.
struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text(verbatim: "\u{265E}\u{FE0E}")
                .font(.system(size: 96))
            Text("Chess")
                .font(.largeTitle.weight(.bold))
            ProgressView()
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Loading"))
    }
}

/// This version is too old for the server: nothing to do but update.
struct UpdateRequiredView: View {
    @Environment(GameModel.self) private var model
    @Environment(\.openURL) private var openURL
    let updateURL: URL?

    var body: some View {
        // Fits an upright phone; on a phone on its side, or with large text, the
        // buttons could fall off the bottom, so it scrolls there.
        CenteredScrollView {
            ContentUnavailableView {
                Label("Update required", systemImage: "arrow.down.app")
            } description: {
                Text("This version of the app no longer works with the server. Install the update to keep playing.")
            } actions: {
                if let updateURL {
                    Button("Update") { openURL(updateURL) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Try again") { Task { await model.retryStart() } }
                    .buttonStyle(.bordered)
            }
        }
    }
}

#Preview("Splash") {
    SplashView()
}
