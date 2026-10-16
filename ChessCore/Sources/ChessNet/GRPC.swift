import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Where a gRPC service listens, from the address the app knows it by:
/// "ws://host:8080/ws" for the game server (gRPC shares its port with the
/// WebSocket channel), "http://host:8081" for auth. "wss"/"https" mean TLS.
public struct GRPCEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var usesTLS: Bool

    public init?(url: URL) {
        guard let host = url.host(), !host.isEmpty else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "ws": usesTLS = false
        case "https", "wss": usesTLS = true
        default: return nil
        }
        self.host = host
        self.port = url.port ?? (usesTLS ? 443 : 80)
    }

    public init(host: String, port: Int, usesTLS: Bool) {
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
    }
}

/// Calls made from the app are short: the server answers in milliseconds or
/// something is wrong, and a spinner should not turn forever.
func callOptions(timeout: Duration) -> CallOptions {
    var options = CallOptions.defaults
    options.timeout = timeout
    return options
}

/// Opens an HTTP/2 connection to `endpoint`, runs `body` with a client on it,
/// and closes the connection. Every call here is rare (sign-in, bootstrap,
/// a health check every few seconds), so a connection per call is fine.
///
/// The transport is Network.framework ("TransportServices"), Apple's own
/// networking: it handles Wi-Fi/cellular switches and Low Data Mode.
@concurrent
func withConnection<Result: Sendable>(
    to endpoint: GRPCEndpoint,
    _ body: @Sendable (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result
) async throws -> Result {
    let transport = try HTTP2ClientTransport.TransportServices(
        target: .dns(host: endpoint.host, port: endpoint.port),
        transportSecurity: endpoint.usesTLS ? .tls : .plaintext)
    return try await withGRPCClient(transport: transport) { client in
        try await body(client)
    }
}
