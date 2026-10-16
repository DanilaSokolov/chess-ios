import SwiftUI

@main
struct ChessApp: App {
    @State private var model = GameModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                #if os(macOS)
                    // The smallest window. A Mac window always shows both
                    // columns of the lobby (the split view never collapses
                    // there), so narrower than the sidebar's least width
                    // (320, see `LobbyView`) plus a usable detail column
                    // (360: the history rows, and a replay board of about
                    // 330 points at the default height) the history would be
                    // squeezed to a sliver. The game screen works at this
                    // size too: side by side, with a board of about 360 points.
                    //
                    // The cost: the window can no longer be made as narrow as
                    // a phone. The lobby comes first: a Mac window never shows
                    // it collapsed anyway, so phone layouts are tested in the
                    // iOS simulator, where they are real. The stacked game
                    // screen is still there on the Mac, in a tall window.
                    .frame(minWidth: 680, minHeight: 520)
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.appBecameActive() }
                }
        }
        #if os(macOS)
            // Wide enough for the lobby and the game history side by side
            // (see `LobbyView`); only the first window's size, the player resizes freely.
            .defaultSize(width: 900, height: 820)
            // The window cannot shrink below the content's least size (the
            // frame above). Said explicitly rather than relying on `.automatic`.
            .windowResizability(.contentMinSize)
        #endif
    }
}
