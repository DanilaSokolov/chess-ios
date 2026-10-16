import ChessNet
import Foundation
import Observation

/// The player's account on this device: signing in and out, and handing the
/// game connection a fresh access token.
///
/// Tokens:
/// - the refresh token lives in a `SecretStore` (the Keychain): it is what
///   keeps the player signed in between launches;
/// - the access token lives only in memory, for 15 minutes; a new one is
///   fetched with the refresh token whenever the old one is about to expire.
@MainActor
@Observable
public final class AccountManager {
    /// Who is signed in, once auth has told us.
    public struct User: Equatable, Sendable {
        public var id: String
        public var name: String
        public var isAnonymous: Bool
    }

    public private(set) var user: User?

    /// The auth service, at the address from the server's bootstrap. Nil: the
    /// server has no accounts, and the app plays as a guest.
    public var client: (any AuthAPI)?

    @ObservationIgnored private let store: any SecretStore
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpires: Date = .distantPast
    @ObservationIgnored private var refreshTask: Task<AuthSession, any Error>?
    /// Adding a login, while auth is being asked: see `upgrade`.
    @ObservationIgnored private var upgradeTask: Task<AuthSession, any Error>?

    /// An access token this close to expiry is renewed before use, so it does
    /// not expire between being sent and being checked.
    static let renewalMargin: TimeInterval = 60

    public init(store: any SecretStore = KeychainSecretStore()) {
        self.store = store
    }

    /// A refresh token is kept: the player is signed in on this device.
    public var hasAccount: Bool { store.read() != nil }

    // MARK: - Signing in

    public func signUpAnonymously() async throws(AuthError) {
        try await start { client throws(AuthError) in try await client.signUpAnonymously() }
    }

    /// `email` is optional; when given, auth sends a code to confirm it.
    public func register(login: String, password: String, email: String = "") async throws(AuthError) {
        try await start { client throws(AuthError) in
            try await client.register(login: login, password: password, email: email)
        }
    }

    public func logIn(login: String, password: String) async throws(AuthError) {
        try await start { client throws(AuthError) in try await client.logIn(login: login, password: password) }
    }

    /// Adds a login to the anonymous account signed in here. The account
    /// stays the same (its id, and so its game history); it gets the login as
    /// its name and stops being anonymous.
    ///
    /// Not `register`: that one makes a new account, for the sign-in screen.
    /// This one is only for an anonymous player who is signed in already.
    ///
    /// Auth answers with a new session and revokes every older refresh token
    /// of the account. A renewal racing with the request would spend the old
    /// token after that and look like a stolen copy, so renewals started
    /// meanwhile wait for the answer instead (see `validAccessToken`).
    public func upgrade(login: String, password: String, email: String = "") async throws(AuthError) {
        if let upgradeTask {  // Asked twice: the first answer decides.
            _ = try? await upgradeTask.value
        }
        // `user` is nil until auth has answered once this launch; then auth decides.
        if user?.isAnonymous == false { throw .alreadyRegistered }
        try await authorized { client, token throws(AuthError) in
            try await self.replaceSession { () async throws(AuthError) -> AuthSession in
                try await client.register(login: login, password: password, email: email, accessToken: token)
            }
        }
    }

    /// Runs a request whose answer replaces the session, holding back
    /// renewals until it is in.
    private func replaceSession(
        with request: @escaping @Sendable () async throws(AuthError) -> AuthSession
    ) async throws(AuthError) {
        // Accepted inside the task (on the main actor, like this method): a
        // renewal waiting for the task finds the new tokens already in place.
        let task = Task { () async throws -> AuthSession in
            let session = try await request()
            self.accept(session)
            return session
        }
        upgradeTask = task
        defer { upgradeTask = nil }
        _ = try await Self.result(of: task)
    }

    // MARK: - Email and password reset

    /// The account's login and email, from auth.
    public func account() async throws(AuthError) -> AccountInfo {
        try await authorized { client, token throws(AuthError) in try await client.account(accessToken: token) }
    }

    /// Sets the email; auth sends a code to it.
    public func setEmail(_ email: String) async throws(AuthError) {
        try await authorized { client, token throws(AuthError) in
            try await client.setEmail(email, accessToken: token)
        }
    }

    public func verifyEmail(code: String) async throws(AuthError) -> AccountInfo {
        try await authorized { client, token throws(AuthError) in
            try await client.verifyEmail(code: code, accessToken: token)
        }
    }

    /// Asks for a reset code by email. Auth answers the same whether or not
    /// the login exists, so this succeeds either way.
    public func requestPasswordReset(login: String) async throws(AuthError) {
        guard let client else { throw .unreachable }
        try await client.requestPasswordReset(login: login)
    }

    /// Sets a new password with the emailed code, and signs in with it.
    public func resetPassword(login: String, code: String, newPassword: String) async throws(AuthError) {
        try await start { client throws(AuthError) in
            try await client.resetPassword(login: login, code: code, newPassword: newPassword)
        }
    }

    /// Calls auth as the signed-in player. A refused token (it expired a
    /// moment ago) is renewed once; refused again, the session is over.
    private func authorized<T: Sendable>(
        _ call: (any AuthAPI, String) async throws(AuthError) -> T
    ) async throws(AuthError) -> T {
        guard let client else { throw .unreachable }
        for attempt in 1...2 {
            guard let token = try await validAccessToken() else { throw .refused(code: "invalid_token") }
            do {
                return try await call(client, token)
            } catch .refused(code: "invalid_token") where attempt == 1 {
                dropAccessToken()
            }
        }
        clear()
        throw .refused(code: "invalid_token")
    }

    private func start(_ request: (any AuthAPI) async throws(AuthError) -> AuthSession) async throws(AuthError) {
        guard let client else { throw .unreachable }
        accept(try await request(client))
    }

    /// Forgets the account here and revokes its refresh token on the server.
    /// Revoking is best effort: offline, the token is forgotten anyway.
    public func signOut() async {
        let token = store.read()
        clear()
        if let token, let client {
            try? await client.logOut(token)
        }
    }

    // MARK: - Access token

    /// A valid access token for the game server, renewed if needed. Nil when
    /// the server has no accounts or the player has none: play as a guest.
    public func validAccessToken(now: Date = .now) async throws(AuthError) -> String? {
        guard client != nil, hasAccount else { return nil }
        if let upgradeTask {
            // Auth is replacing the tokens: once the task is done the new
            // session is accepted; if adding the login failed, the old tokens
            // still work.
            _ = try? await upgradeTask.value
            guard hasAccount else { return nil }
        }
        if let accessToken, now.addingTimeInterval(Self.renewalMargin) < accessExpires {
            return accessToken
        }
        return try await renew().accessToken
    }

    /// The game server refused our access token: get a new one next time.
    public func dropAccessToken() {
        accessToken = nil
        accessExpires = .distantPast
    }

    /// Trades the refresh token for a new session, once even when asked from
    /// several places at once.
    ///
    /// Why it matters: each refresh token works once. Two connections renewing
    /// together would both send the same token; auth would take the second for
    /// a stolen copy and revoke the whole session. So the second caller waits
    /// for the first one's answer instead of asking again.
    private func renew() async throws(AuthError) -> AuthSession {
        if let refreshTask {
            return try await Self.result(of: refreshTask)
        }
        guard let client, let token = store.read() else { throw .refused(code: "invalid_token") }
        let task = Task { try await client.refresh(token) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let session = try await Self.result(of: task)
            accept(session)
            return session
        } catch {
            if error.isSignedOut {
                clear()  // Revoked: only signing in again helps.
            }
            throw error
        }
    }

    /// `Task` erases typed throws; this puts the type back.
    private static func result(of task: Task<AuthSession, any Error>) async throws(AuthError) -> AuthSession {
        do {
            return try await task.value
        } catch let error as AuthError {
            throw error
        } catch {
            throw .unreachable
        }
    }

    private func accept(_ session: AuthSession, now: Date = .now) {
        store.write(session.refreshToken)
        accessToken = session.accessToken
        accessExpires = now.addingTimeInterval(TimeInterval(session.expiresIn))
        user = User(id: session.userID, name: session.name, isAnonymous: session.anonymous)
    }

    private func clear() {
        store.write(nil)
        dropAccessToken()
        user = nil
    }
}
