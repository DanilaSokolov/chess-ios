import ChessNet
import SwiftUI

/// Waiting for an opponent of the same time control.
struct SearchingView: View {
    @Environment(GameModel.self) private var model
    let timeControl: TimeControl

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Looking for an opponent, \(timeControl.description)…")
                .font(.headline)
            Button("Cancel", role: .cancel) {
                Task { await model.cancelSearch() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}
