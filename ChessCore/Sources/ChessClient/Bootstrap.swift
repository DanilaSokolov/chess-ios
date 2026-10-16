import ChessNet
import Foundation

/// Fetches the bootstrap, falling back to the last answer for this app version.
public struct BootstrapLoader: Sendable {
    /// The splash screen waits at most this long for the server.
    public static let timeout: Duration = .seconds(3)

    public let appVersion: String
    public let language: String?

    public init(
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        language: String? = Bundle.main.preferredLocalizations.first
    ) {
        self.appVersion = appVersion
        self.language = language
    }

    /// The server's answer, or nil if it could not be reached in time.
    public func fetch(from webSocketURL: URL) async -> Bootstrap? {
        await Bootstrap.fetch(
            from: webSocketURL, clientVersion: appVersion, language: language, timeout: Self.timeout)
    }

    // MARK: - Cache

    /// A stored answer, tagged with the app version it was given to: after an
    /// update the old verdict no longer applies.
    struct Cached: Codable {
        var appVersion: String
        var bootstrap: Bootstrap
    }

    public func cached(in data: Data?) -> Bootstrap? {
        guard let data, let cached = try? JSONDecoder().decode(Cached.self, from: data),
            cached.appVersion == appVersion
        else { return nil }
        return cached.bootstrap
    }

    public func cache(_ bootstrap: Bootstrap) -> Data? {
        try? JSONEncoder().encode(Cached(appVersion: appVersion, bootstrap: bootstrap))
    }
}
