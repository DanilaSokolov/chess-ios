import ChessClient
import SwiftUI

/// Picks the screen. Which one is decided by `ClientState.screen`, so the
/// view never has to handle "a game screen without a game".
struct ContentView: View {
    @Environment(GameModel.self) private var model
    @Namespace private var transition

    var body: some View {
        Group {
            switch model.launch {
            case .loading:
                SplashView()
            case .updateRequired(let updateURL):
                UpdateRequiredView(updateURL: updateURL)
            case .ready:
                screen
            }
        }
        .animation(.smooth(duration: 0.4), value: model.launch)
        .task { await model.start() }
    }

    @ViewBuilder
    private var screen: some View {
        Group {
            if model.settings.account == nil {
                AuthView()
            } else {
                switch model.state.screen {
                case .lobby:
                    LobbyView()
                case .searching(let timeControl):
                    SearchingView(timeControl: timeControl)
                case .room(let room):
                    RoomView(room: room)
                case .game(let game):
                    GameView(game: game)
                }
            }
        }
        .environment(\.screenTransition, transition)
        // Animate moving between screens, not every change within one.
        .animation(.smooth(duration: 0.5), value: model.state.screen.kind)
        .animation(.default, value: model.settings.account)
    }
}
