import SwiftUI

#if os(iOS)
    import UIKit
#endif

extension View {
    /// How games usually take over an iPhone or iPad while being played:
    /// - no status bar, and the home indicator fades when not in use;
    /// - swipes from the screen's top and bottom edges go to the game first, so
    ///   dragging a piece near an edge does not pull down Control Center or
    ///   leave the app (a second swipe still does);
    /// - while `keepsAwake`, the screen does not dim and lock mid-game.
    /// On the Mac the window is the player's: it goes full screen with the
    /// green button, as every Mac app does.
    func gameFullScreen(keepsAwake: Bool) -> some View {
        modifier(GameFullScreen(keepsAwake: keepsAwake))
    }
}

private struct GameFullScreen: ViewModifier {
    let keepsAwake: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .vertical)
                .onAppear { setIdleTimerDisabled(keepsAwake) }
                .onChange(of: keepsAwake) { _, keepsAwake in setIdleTimerDisabled(keepsAwake) }
                // Leaving the game screen hands sleeping back to the system.
                .onDisappear { setIdleTimerDisabled(false) }
        #else
            content
        #endif
    }

    #if os(iOS)
        private func setIdleTimerDisabled(_ disabled: Bool) {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    #endif
}
