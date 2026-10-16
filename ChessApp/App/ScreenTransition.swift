import SwiftUI

extension EnvironmentValues {
    /// Shared by screens so an element can travel from one screen to the next
    /// (`matchedGeometryEffect`) instead of vanishing and reappearing.
    @Entry var screenTransition: Namespace.ID?
}

/// IDs of elements that travel between screens.
enum ScreenTransitionID: Hashable {
    /// "The game has begun": from the room's countdown to over the board.
    case gameStarted
}

extension View {
    /// Lets this view travel to or from the view with the same `id` on the next screen.
    func travels(as id: ScreenTransitionID, in namespace: Namespace.ID?) -> some View {
        modifier(Travels(id: id, namespace: namespace))
    }
}

private struct Travels: ViewModifier {
    let id: ScreenTransitionID
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}
