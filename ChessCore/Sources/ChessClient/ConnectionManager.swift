import ChessNet
import Foundation
import Observation

/// What a connection manager reports to its owner. Named after the
/// delegating object, like `tableView(_:didSelectRowAt:)`, so a type can
/// tell several managers apart and the call site reads as a sentence.
@MainActor
public protocol ConnectionManagerDelegate: AnyObject {
    /// The server greeted us. `isResumed` is false when it did not recognise our token.
    func connectionManager(
        _ manager: ConnectionManager, didWelcomeAs name: String, resumeToken: String, isResumed: Bool)
    func connectionManager(_ manager: ConnectionManager, didReceive event: ServerEvent)
    /// The live connection dropped; `reason` is nil when nothing went wrong.
    func connectionManager(_ manager: ConnectionManager, didDisconnectWithReason reason: String?)
}

/// The socket side of the client: connecting, waiting for Welcome, passing
/// events on and reconnecting with growing pauses. It knows nothing about
/// games or rooms; the delegate decides what an event means.
@MainActor
@Observable
public final class ConnectionManager {
    public enum Status: Equatable, Sendable {
        case offline
        case online
        /// Lost while there was something to resume; retrying with the resume token.
        case reconnecting(attempt: Int)
    }

    public private(set) var status: Status = .offline
    public weak var delegate: any ConnectionManagerDelegate?

    /// Give up reconnecting after this long; the server keeps a seat for 60 s.
    public static let reconnectBudget: TimeInterval = 90

    @ObservationIgnored private var client: GameClient?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    /// Told to the server in Hello. The language the app's interface is shown
    /// in, which may differ from the device's when the app lacks a translation.
    public var language: String? = Bundle.main.preferredLocalizations.first

    public init() {}

    public var isConnected: Bool { client != nil }

    /// Opens a connection and waits for Welcome. Returns false on failure.
    /// `accessToken` signs in with an account; nil plays as a guest.
    @discardableResult
    public func connect(to url: URL, resumeToken: String?, accessToken: String? = nil) async -> Bool {
        let client = GameClient(
            url: url, playerName: nil, resumeToken: resumeToken, language: language, accessToken: accessToken)
        self.client = client
        let welcomed = AsyncStream<Bool>.makeStream()
        Task { await listen(to: client, welcomed: welcomed.continuation) }
        await client.connect()
        for await ok in welcomed.stream {
            return ok
        }
        return false
    }

    public func send(_ command: ClientCommand) async throws {
        try await client?.send(command)
    }

    /// Closes the connection on purpose and stops any reconnecting.
    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        let client = self.client
        self.client = nil
        status = .offline
        await client?.disconnect()
    }

    /// Keeps trying to reconnect while `shouldContinue` holds, pausing longer
    /// after each failure, and calls `onGiveUp` after `reconnectBudget`.
    /// `accessToken` is asked before every attempt: a long outage can outlive
    /// a 15-minute token.
    ///
    /// Failed attempts also end in a dropped connection, whose handler calls
    /// this again; that must not start a second loop, hence the guard.
    public func keepReconnecting(
        to url: URL, resumeToken: String?,
        accessToken: @escaping @MainActor () async -> String? = { nil },
        while shouldContinue: @escaping @MainActor () -> Bool,
        onGiveUp: @escaping @MainActor () -> Void
    ) {
        guard reconnectTask == nil else { return }
        reconnectTask = Task {
            defer { reconnectTask = nil }
            let started = Date.now
            for attempt in 1... {
                guard shouldContinue(), !Task.isCancelled else { return }
                status = .reconnecting(attempt: attempt)
                if await connect(to: url, resumeToken: resumeToken, accessToken: await accessToken()) {
                    return
                }
                if Date.now.timeIntervalSince(started) > Self.reconnectBudget {
                    status = .offline
                    onGiveUp()
                    return
                }
                try? await Task.sleep(for: Self.pause(afterAttempt: attempt))
            }
        }
    }

    public var isReconnecting: Bool { reconnectTask != nil }

    /// How long to wait after a failed attempt: 0.5 s, doubling, at most 5 s.
    /// Quick at first for a short blip, then gentle on a server that is down.
    public nonisolated static func pause(afterAttempt attempt: Int) -> Duration {
        let seconds = 0.5 * pow(2, Double(min(attempt, 10) - 1))
        return .milliseconds(Int(min(seconds, 5) * 1000))
    }

    private func listen(to client: GameClient, welcomed: AsyncStream<Bool>.Continuation) async {
        defer { welcomed.finish() }
        for await event in client.events {
            // A replaced client may still deliver its last events; ignore them.
            guard client === self.client else { return }
            switch event {
            case .server(.welcome(_, let name, let token, let resumed)):
                status = .online
                delegate?.connectionManager(self, didWelcomeAs: name, resumeToken: token, isResumed: resumed)
                welcomed.yield(true)
                welcomed.finish()
            case .server(let event):
                delegate?.connectionManager(self, didReceive: event)
            case .disconnected(let reason):
                welcomed.yield(false)
                self.client = nil
                status = .offline
                delegate?.connectionManager(self, didDisconnectWithReason: reason?.text)
            }
        }
    }
}

extension DisconnectReason {
    /// What to tell the player, after "Connection lost:".
    public var text: String {
        switch self {
        case .network(let text): text
        case .unreadableMessage:
            String(localized: "the server sent a message this version of the app cannot read", bundle: .module)
        }
    }
}
