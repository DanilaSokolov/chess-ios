import ChessProto
import Foundation
import GRPCCore
import GRPCProtobuf

public enum ServerHealth {
    /// Whether the game server answers the standard gRPC health check
    /// (grpc.health.v1.Health/Check) with SERVING, and how long it took,
    /// connecting included.
    @concurrent public static func check(_ webSocketURL: URL, timeout: Duration = .seconds(3)) async -> Duration? {
        guard let endpoint = GRPCEndpoint(url: webSocketURL) else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await withConnection(to: endpoint) { client in
                try await Grpc_Health_V1_Health.Client(wrapping: client)
                    .check(Grpc_Health_V1_HealthCheckRequest(), options: callOptions(timeout: timeout))
            }
            return response.status == .serving ? clock.now - start : nil
        } catch {
            return nil
        }
    }
}
