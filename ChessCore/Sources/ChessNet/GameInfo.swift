import ChessProto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
internal import SwiftProtobuf

/// What the server tells the app before it connects: whether this version may
/// play, and settings that should not be baked into the app. Fetched on the
/// splash screen with the gRPC call chess.v1.GameInfo/Bootstrap. Codable, so
/// the last answer can be kept for starting offline.
public struct Bootstrap: Codable, Equatable, Sendable {
    public struct Client: Codable, Equatable, Sendable {
        public var status: VersionStatus
        public var minVersion: String
        public var latestVersion: String
        public var updateURL: URL?
    }

    public struct WireTimeControl: Codable, Equatable, Sendable {
        public var initialSeconds: Int
        public var incrementSeconds: Int
    }

    /// Where the app signs in; absent when the server has no accounts.
    public struct Auth: Codable, Equatable, Sendable {
        public var url: URL
    }

    public var client: Client
    public var timeControls: [WireTimeControl]
    public var auth: Auth?
    /// Where the app reads game history; absent when the server keeps none.
    /// Optional, so answers cached by older versions still decode.
    public var historyURL: URL?

    /// The lobby's choices; the built-in presets if the server sent none.
    public var lobbyTimeControls: [TimeControl] {
        let list = timeControls.map {
            TimeControl(initialSeconds: $0.initialSeconds, incrementSeconds: $0.incrementSeconds)
        }
        return list.isEmpty ? TimeControl.presets : list
    }
}

/// Whether this version of the app may play. The server decides, so the
/// rules can change without an app release.
public enum VersionStatus: String, Codable, Sendable {
    /// Current.
    case supported
    /// May play; a newer version exists.
    case outdated
    /// Too old for this server: must update before connecting.
    case unsupported

    /// A status added to the server later reads as "outdated": the app keeps
    /// working and suggests an update, rather than locking people out.
    public init(from decoder: any Swift.Decoder) throws {  // Not SwiftProtobuf.Decoder.
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VersionStatus(rawValue: raw) ?? .outdated
    }

    init(_ wire: Chess_V1_ClientStatus) {
        self =
            switch wire {
            case .supported: .supported
            case .unsupported: .unsupported
            // OUTDATED, and anything this version of the app does not know.
            default: .outdated
            }
    }
}

extension Bootstrap {
    init(_ wire: Chess_V1_BootstrapResponse) {
        self.init(
            client: Client(
                status: VersionStatus(wire.status), minVersion: wire.minVersion, latestVersion: wire.latestVersion,
                updateURL: URL(string: wire.updateURL)),
            timeControls: wire.timeControls.map {
                WireTimeControl(initialSeconds: Int($0.initialSeconds), incrementSeconds: Int($0.incrementSeconds))
            },
            auth: URL(string: wire.authURL).map(Auth.init(url:)),
            historyURL: URL(string: wire.historyURL))
    }

    /// Asks the game server (gRPC on the WebSocket's host and port). Nil if it
    /// does not answer within `timeout`: the app then starts from its cache.
    @concurrent public static func fetch(
        from webSocketURL: URL, clientVersion: String, language: String?, timeout: Duration
    ) async -> Bootstrap? {
        guard let endpoint = GRPCEndpoint(url: webSocketURL) else { return nil }
        let request = Chess_V1_BootstrapRequest.with {
            $0.clientVersion = clientVersion
            $0.protocolVersion = protocolVersion
            $0.language = language ?? ""
        }
        let response = try? await withConnection(to: endpoint) { client in
            try await Chess_V1_GameInfo.Client(wrapping: client).bootstrap(
                request, options: callOptions(timeout: timeout))
        }
        return response.map(Bootstrap.init)
    }
}
