import ChessCore
import Foundation
import Observation

/// Everything the app remembers between launches, in one place with typed
/// keys instead of strings scattered over the model and the views.
@MainActor
@Observable
public final class AppSettings {
    /// How the player last signed in on this device. The account itself (its
    /// refresh token) is in the Keychain, see `AccountManager`; this only
    /// remembers that the sign-in screen was passed, and how.
    public enum Account: String, Sendable {
        /// An account without a login, made for this device.
        case anonymous
        /// Login and password.
        case login
    }

    /// The stored names; they are the same as before this type existed, so
    /// existing installs keep their settings.
    enum Key: String {
        case account, serverURL, side, resumeToken, lastBootstrap
        case prefersBoard3D = "board3D"
        case prefersFacetedPieces = "facetedPieces"
    }

    public static let defaultServerURL = "ws://localhost:8080/ws"

    @ObservationIgnored private let defaults: UserDefaults

    public var account: Account? {
        didSet { defaults.set(account?.rawValue, forKey: Key.account.rawValue) }
    }
    public var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Key.serverURL.rawValue) }
    }
    /// Preferred side when searching or in a room's first game; nil for either.
    public var side: PieceColor? {
        didSet { defaults.set(side.map { $0 == .white ? "white" : "black" }, forKey: Key.side.rawValue) }
    }
    /// Identifies this player to the server across connections.
    public var resumeToken: String? {
        didSet { defaults.set(resumeToken, forKey: Key.resumeToken.rawValue) }
    }
    public var prefersBoard3D: Bool {
        didSet { defaults.set(prefersBoard3D, forKey: Key.prefersBoard3D.rawValue) }
    }
    /// 3D pieces with 8 facets instead of smooth ones.
    public var prefersFacetedPieces: Bool {
        didSet { defaults.set(prefersFacetedPieces, forKey: Key.prefersFacetedPieces.rawValue) }
    }

    /// The server's last bootstrap answer, for starting without a connection.
    public var lastBootstrap: Data? {
        didSet { defaults.set(lastBootstrap, forKey: Key.lastBootstrap.rawValue) }
    }

    /// `defaults` is `.standard` in the app; tests pass a scratch suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        account = defaults.string(forKey: Key.account.rawValue).flatMap(Account.init(rawValue:))
        serverURL = defaults.string(forKey: Key.serverURL.rawValue) ?? Self.defaultServerURL
        side =
            switch defaults.string(forKey: Key.side.rawValue) {
            case "white": .white
            case "black": .black
            default: nil
            }
        resumeToken = defaults.string(forKey: Key.resumeToken.rawValue)
        lastBootstrap = defaults.data(forKey: Key.lastBootstrap.rawValue)
        prefersBoard3D = defaults.bool(forKey: Key.prefersBoard3D.rawValue)
        prefersFacetedPieces = defaults.bool(forKey: Key.prefersFacetedPieces.rawValue)
    }

    /// The server address, if it is a WebSocket URL.
    public var webSocketURL: URL? {
        guard let url = URL(string: serverURL), url.scheme == "ws" || url.scheme == "wss" else { return nil }
        return url
    }
}
