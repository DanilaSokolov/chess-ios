import ChessProto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
internal import SwiftProtobuf

/// What the auth service returns after any successful sign-in or refresh.
public struct AuthSession: Equatable, Sendable {
    public var userID: String
    public var name: String
    public var anonymous: Bool
    /// A JWT for the game server, valid for `expiresIn` seconds (15 minutes).
    public var accessToken: String
    public var expiresIn: Int
    /// Trades for the next session. Long-lived and secret: kept in the Keychain.
    public var refreshToken: String

    public init(
        userID: String, name: String, anonymous: Bool, accessToken: String, expiresIn: Int, refreshToken: String
    ) {
        self.userID = userID
        self.name = name
        self.anonymous = anonymous
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
    }

    init(_ wire: Chess_Auth_V1_Session) {
        self.init(
            userID: wire.userID, name: wire.name, anonymous: wire.anonymous, accessToken: wire.accessToken,
            expiresIn: Int(wire.expiresInSeconds), refreshToken: wire.refreshToken)
    }
}

/// Why a request to auth failed.
public enum AuthError: Error, Equatable, Sendable {
    /// The service refused, with a reason such as "login_taken" (from
    /// google.rpc.ErrorInfo, lower-cased).
    case refused(code: String)
    /// Too many wrong passwords: signing in is locked for this long.
    case temporarilyLocked(retryAfterSeconds: Int)
    /// Adding a login to an account that already has one (reason
    /// "ALREADY_REGISTERED"): it was added before, maybe by a request whose
    /// answer was lost. The anonymous session is gone; sign in with the login.
    case alreadyRegistered
    /// No answer: no network, or the service is down.
    case unreachable
    /// An answer we could not read.
    case badResponse

    /// The session is over: signed out elsewhere, revoked after a suspected
    /// theft, or the account is banned. Retrying cannot help.
    public var isSignedOut: Bool { self == .refused(code: "invalid_token") || self == .refused(code: "banned") }
}

/// The account as its owner sees it.
public struct AccountInfo: Sendable, Equatable {
    public var login: String
    public var email: String
    public var isEmailVerified: Bool

    public init(login: String, email: String, isEmailVerified: Bool) {
        self.login = login
        self.email = email
        self.isEmailVerified = isEmailVerified
    }
}

/// The auth service's calls, as the app uses them. A protocol so the account
/// logic can be tested without a server.
public protocol AuthAPI: Sendable {
    func signUpAnonymously() async throws(AuthError) -> AuthSession
    /// `email` is optional: empty for none.
    func register(login: String, password: String, email: String) async throws(AuthError) -> AuthSession
    /// Adds a login to the anonymous account `accessToken` belongs to: the
    /// same user id (and so the same game history), now named `login`. The
    /// answer is a new session; every older refresh token of the account is
    /// revoked by it.
    func register(login: String, password: String, email: String, accessToken: String) async throws(AuthError)
        -> AuthSession
    func logIn(login: String, password: String) async throws(AuthError) -> AuthSession
    func refresh(_ refreshToken: String) async throws(AuthError) -> AuthSession
    func logOut(_ refreshToken: String) async throws(AuthError)

    // Signed in: `accessToken` proves who asks.
    func account(accessToken: String) async throws(AuthError) -> AccountInfo
    func setEmail(_ email: String, accessToken: String) async throws(AuthError)
    func verifyEmail(code: String, accessToken: String) async throws(AuthError) -> AccountInfo

    // Forgot the password: no sign-in.
    func requestPasswordReset(login: String) async throws(AuthError)
    func resetPassword(login: String, code: String, newPassword: String) async throws(AuthError) -> AuthSession
}

/// chess.auth.v1.AuthService over gRPC (proto/chess/auth/v1/auth.proto).
public struct AuthClient: AuthAPI {
    public let endpoint: GRPCEndpoint
    static let timeout: Duration = .seconds(10)

    public init(endpoint: GRPCEndpoint) {
        self.endpoint = endpoint
    }

    /// From the address the server gives in its bootstrap, e.g. "http://localhost:8081".
    public init?(url: URL) {
        guard let endpoint = GRPCEndpoint(url: url) else { return nil }
        self.endpoint = endpoint
    }

    typealias Service = Chess_Auth_V1_AuthService.Client<HTTP2ClientTransport.TransportServices>

    public func signUpAnonymously() async throws(AuthError) -> AuthSession {
        try await session { try await $0.signUpAnonymously(.init(), options: $1) }
    }

    public func register(login: String, password: String, email: String) async throws(AuthError) -> AuthSession {
        let request = Chess_Auth_V1_RegisterRequest.with {
            $0.login = login
            $0.password = password
            $0.email = email
        }
        return try await session { try await $0.register(request, options: $1) }
    }

    public func register(login: String, password: String, email: String, accessToken: String) async throws(AuthError)
        -> AuthSession
    {
        let request = Chess_Auth_V1_RegisterRequest.with {
            $0.login = login
            $0.password = password
            $0.email = email
        }
        return AuthSession(try await call(accessToken) { try await $0.register(request, metadata: $1, options: $2) })
    }

    public func logIn(login: String, password: String) async throws(AuthError) -> AuthSession {
        let request = Chess_Auth_V1_LogInRequest.with {
            $0.login = login
            $0.password = password
        }
        return try await session { try await $0.logIn(request, options: $1) }
    }

    public func refresh(_ refreshToken: String) async throws(AuthError) -> AuthSession {
        let request = Chess_Auth_V1_RefreshRequest.with { $0.refreshToken = refreshToken }
        return try await session { try await $0.refresh(request, options: $1) }
    }

    public func logOut(_ refreshToken: String) async throws(AuthError) {
        let request = Chess_Auth_V1_LogOutRequest.with { $0.refreshToken = refreshToken }
        _ = try await call { try await $0.logOut(request, options: $1) }
    }

    public func account(accessToken: String) async throws(AuthError) -> AccountInfo {
        AccountInfo(try await call(accessToken) { try await $0.getAccount(.init(), metadata: $1, options: $2) })
    }

    public func setEmail(_ email: String, accessToken: String) async throws(AuthError) {
        let request = Chess_Auth_V1_SetEmailRequest.with { $0.email = email }
        _ = try await call(accessToken) { try await $0.setEmail(request, metadata: $1, options: $2) }
    }

    public func verifyEmail(code: String, accessToken: String) async throws(AuthError) -> AccountInfo {
        let request = Chess_Auth_V1_VerifyEmailRequest.with { $0.code = code }
        return AccountInfo(try await call(accessToken) { try await $0.verifyEmail(request, metadata: $1, options: $2) })
    }

    public func requestPasswordReset(login: String) async throws(AuthError) {
        let request = Chess_Auth_V1_RequestPasswordResetRequest.with { $0.login = login }
        _ = try await call { try await $0.requestPasswordReset(request, options: $1) }
    }

    public func resetPassword(login: String, code: String, newPassword: String) async throws(AuthError)
        -> AuthSession
    {
        let request = Chess_Auth_V1_ResetPasswordRequest.with {
            $0.login = login
            $0.code = code
            $0.newPassword = newPassword
        }
        return try await session { try await $0.resetPassword(request, options: $1) }
    }

    /// A call for the signed-in player: the access token goes in the metadata.
    private func call<Response: Sendable>(
        _ accessToken: String, _ rpc: @Sendable (Service, Metadata, CallOptions) async throws -> Response
    ) async throws(AuthError) -> Response {
        var headers = Metadata()
        headers.addString("Bearer \(accessToken)", forKey: "authorization")
        let metadata = headers
        return try await call { try await rpc($0, metadata, $1) }
    }

    private func session(
        _ rpc: @Sendable (Service, CallOptions) async throws -> Chess_Auth_V1_Session
    ) async throws(AuthError) -> AuthSession {
        AuthSession(try await call(rpc))
    }

    /// Runs one call and turns a gRPC failure into an `AuthError`.
    private func call<Response: Sendable>(
        _ rpc: @Sendable (Service, CallOptions) async throws -> Response
    ) async throws(AuthError) -> Response {
        do {
            return try await withConnection(to: endpoint) { client in
                try await rpc(Service(wrapping: client), callOptions(timeout: Self.timeout))
            }
        } catch let error as RPCError {
            throw Self.authError(from: error)
        } catch {
            throw .unreachable
        }
    }

    /// The reason auth gave (google.rpc.ErrorInfo), or what the status code
    /// says when there is none: a refusal is told apart from an outage.
    static func authError(from error: RPCError) -> AuthError {
        if let status = try? error.unpackGoogleRPCStatus(),
            let info = status.details.lazy.compactMap(\.errorInfo).first
        {
            let reason = info.reason.lowercased()
            switch reason {
            case "temporarily_locked":
                return .temporarilyLocked(retryAfterSeconds: Int(info.metadata["retry_after_seconds"] ?? "") ?? 900)
            case "already_registered":
                return .alreadyRegistered
            default:
                return .refused(code: reason)
            }
        }
        switch error.code {
        case .unauthenticated: return .refused(code: "invalid_token")
        case .unavailable, .deadlineExceeded, .cancelled: return .unreachable
        default: return .refused(code: "grpc_\(error.code)")
        }
    }
}

extension AccountInfo {
    init(_ wire: Chess_Auth_V1_Account) {
        self.init(login: wire.login, email: wire.email, isEmailVerified: wire.emailVerified)
    }
}
