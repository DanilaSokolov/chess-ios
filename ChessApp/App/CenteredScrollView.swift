import SwiftUI

/// Centres its content when it fits and scrolls it when it does not.
///
/// For full-screen pages that are a single column of fixed-size parts (sign-in,
/// "update required"). They fit an upright phone, but a phone on its side, or the
/// outer display of iPhone Duo on its side, is only about 400 pt tall, and so is
/// any screen with the keyboard up. A plain `VStack` would then cut off its top
/// and bottom; this lets the player scroll to them instead.
struct CenteredScrollView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // The reader measures the visible area (inside the safe area and above
        // the keyboard), so the content is centred in what the player can see.
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            // No rubber-banding when everything fits: the page should feel still.
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
