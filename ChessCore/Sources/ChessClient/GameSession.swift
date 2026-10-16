import ChessCore
import ChessNet
import Foundation

/// A game as the client sees it: the server's state plus what only the
/// client knows, such as when the clocks were last synced.
public struct GameSession: Hashable, Sendable {
    public struct Outcome: Hashable, Sendable {
        public var result: GameResult
        public var termination: Termination
    }

    public var state: GameState
    /// When `state.clocks` was received; the running clock counts from here.
    public var clocksReceived: Date
    public var outcome: Outcome?
    /// When the absent opponent loses by abandonment.
    public var opponentDeadline: Date?

    public init(_ state: GameState, received: Date) {
        self.state = state
        clocksReceived = received
        if !state.opponentConnected {
            opponentDeadline = received.addingTimeInterval(state.opponentReconnectWithin.seconds)
        }
    }

    public var id: String { state.id }
    public var color: PieceColor { state.color }
    public var position: Position { state.position }
    public var moves: [Move] { state.moves }
    public var isOver: Bool { outcome != nil }
    public var isMyTurn: Bool { !isOver && position.sideToMove == color }

    /// Time left for `side` at `now`, counting down the running clock.
    public func remaining(_ side: PieceColor, at now: Date) -> Duration {
        let base = state.clocks[side]
        guard !isOver, position.sideToMove == side else { return base }
        return max(.zero, base - .seconds(now.timeIntervalSince(clocksReceived)))
    }
}
