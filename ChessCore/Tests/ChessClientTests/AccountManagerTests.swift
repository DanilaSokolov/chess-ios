import ChessNet
import Foundation
import Synchronization
import Testing

@testable import ChessClient

/// Auth without a server: answers from a table, and counts the calls.
final class FakeAuth: AuthAPI {
    let replies = Mutex<[String: Result<AuthSession?, AuthError>]>([:])
    let calls = Mutex<[String]>([])
    /// Slows answers down, so concurrent requests really overlap.
    let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    static func session(_ id: String, refresh: String, expiresIn: Int = 900) -> AuthSession {
        AuthSession(
            userID: "u1", name: "anonim\(id)", anonymous: true, accessToken: "access-\(id)", expiresIn: expiresIn,
            refreshToken: refresh)
    }

    /// The same account as `session` ("u1"), with a login added.
    static func upgraded(_ login: String, refresh: String) -> AuthSession {
        AuthSession(
            userID: "u1", name: login, anonymous: false, accessToken: "access-\(login)", expiresIn: 900,
            refreshToken: refresh)
    }

    func reply(_ method: String, _ result: Result<AuthSession?, AuthError>) {
        replies.withLock { $0[method] = result }
    }

    private func answer(_ method: String) async throws(AuthError) -> AuthSession? {
        calls.withLock { $0.append(method) }
        try? await Task.sleep(for: delay)
        guard let result = replies.withLock({ $0[method] }) else { throw .unreachable }
        return try result.get()
    }

    private func session(_ method: String) async throws(AuthError) -> AuthSession {
        guard let session = try await answer(method) else { throw .badResponse }
        return session
    }

    func signUpAnonymously() async throws(AuthError) -> AuthSession { try await session("signUpAnonymously") }
    func register(login: String, password: String, email: String) async throws(AuthError) -> AuthSession {
        try await session("register")
    }
    func logIn(login: String, password: String) async throws(AuthError) -> AuthSession { try await session("logIn") }

    /// The access tokens signed-in calls came with, in order.
    let accessTokens = Mutex<[String]>([])

    func register(login: String, password: String, email: String, accessToken: String) async throws(AuthError)
        -> AuthSession
    {
        try signedIn("upgrade")
        accessTokens.withLock { $0.append(accessToken) }
        try? await Task.sleep(for: delay)
        guard let result = replies.withLock({ $0["upgrade"] }) else { throw .unreachable }
        guard let session = try result.get() else { throw .badResponse }
        return session
    }
    func refresh(_ refreshToken: String) async throws(AuthError) -> AuthSession { try await session("refresh") }
    func logOut(_ refreshToken: String) async throws(AuthError) { _ = try await answer("logOut") }

    let accountInfo = Mutex(AccountInfo(login: "alice", email: "", isEmailVerified: false))
    let refuseNextToken = Mutex(false)

    private func signedIn(_ method: String) throws(AuthError) {
        calls.withLock { $0.append(method) }
        if refuseNextToken.withLock({ refuse in
            defer { refuse = false }
            return refuse
        }) {
            throw .refused(code: "invalid_token")
        }
    }

    func account(accessToken: String) async throws(AuthError) -> AccountInfo {
        try signedIn("account")
        return accountInfo.withLock { $0 }
    }
    func setEmail(_ email: String, accessToken: String) async throws(AuthError) {
        try signedIn("setEmail")
        accountInfo.withLock {
            $0.email = email
            $0.isEmailVerified = false
        }
    }
    func verifyEmail(code: String, accessToken: String) async throws(AuthError) -> AccountInfo {
        try signedIn("verifyEmail")
        guard code == "123456" else { throw .refused(code: "invalid_code") }
        return accountInfo.withLock {
            $0.isEmailVerified = true
            return $0
        }
    }
    func requestPasswordReset(login: String) async throws(AuthError) { _ = try await answer("requestPasswordReset") }
    func resetPassword(login: String, code: String, newPassword: String) async throws(AuthError) -> AuthSession {
        try await session("resetPassword")
    }
}

@MainActor
private func manager(_ store: MemorySecretStore = MemorySecretStore(), auth: FakeAuth) -> AccountManager {
    let accounts = AccountManager(store: store)
    accounts.client = auth
    return accounts
}

@MainActor
struct AccountManagerTests {
    @Test func guestWithoutAccounts() async throws {
        let accounts = AccountManager(store: MemorySecretStore())
        #expect(try await accounts.validAccessToken() == nil, "no auth configured: play as a guest")
    }

    @Test func anonymousSignUpKeepsTheRefreshToken() async throws {
        let store = MemorySecretStore()
        let auth = FakeAuth()
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        let accounts = manager(store, auth: auth)
        try await accounts.signUpAnonymously()
        #expect(store.read() == "r1")
        #expect(accounts.user?.name == "anonim1")
        // Fresh: no second request.
        #expect(try await accounts.validAccessToken() == "access-1")
        #expect(auth.calls.withLock { $0 } == ["signUpAnonymously"])
    }

    @Test func expiringTokenIsRenewedOnceForConcurrentCallers() async throws {
        let store = MemorySecretStore("r1")
        let auth = FakeAuth(delay: .milliseconds(200))
        auth.reply("refresh", .success(FakeAuth.session("2", refresh: "r2")))
        let accounts = manager(store, auth: auth)
        // Two connections asking at once, as when the app wakes up.
        async let a = accounts.validAccessToken()
        async let b = accounts.validAccessToken()
        let tokens = try await [a, b]
        #expect(tokens == ["access-2", "access-2"])
        #expect(auth.calls.withLock { $0 } == ["refresh"], "the refresh token must be used once")
        #expect(store.read() == "r2")
    }

    @Test func revokedRefreshSignsOut() async throws {
        let auth = FakeAuth()
        auth.reply("refresh", .failure(.refused(code: "invalid_token")))
        let accounts = manager(MemorySecretStore("stolen"), auth: auth)
        await #expect(throws: AuthError.refused(code: "invalid_token")) {
            try await accounts.validAccessToken()
        }
        #expect(!accounts.hasAccount)
    }

    @Test func bannedAccountIsSignedOut() async throws {
        let auth = FakeAuth()
        auth.reply("refresh", .failure(.refused(code: "banned")))
        let accounts = manager(MemorySecretStore("r1"), auth: auth)
        await #expect(throws: AuthError.refused(code: "banned")) {
            try await accounts.validAccessToken()
        }
        #expect(!accounts.hasAccount, "a ban is not retried")
        #expect(authErrorText(.refused(code: "banned")) == "This account is blocked.")
    }

    @Test func lockedLoginSaysForHowLong() {
        #expect(
            authErrorText(.temporarilyLocked(retryAfterSeconds: 900))
                == "Too many wrong passwords. Try again in 15 minutes.")
        #expect(
            authErrorText(.temporarilyLocked(retryAfterSeconds: 30))
                == "Too many wrong passwords. Try again in 1 minute.", "rounded up, never 0")
    }

    @Test func emailIsSetAndConfirmed() async throws {
        let auth = FakeAuth()
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        let accounts = manager(auth: auth)
        try await accounts.signUpAnonymously()
        try await accounts.setEmail("alice@example.com")
        await #expect(throws: AuthError.refused(code: "invalid_code")) {
            try await accounts.verifyEmail(code: "000000")
        }
        let info = try await accounts.verifyEmail(code: "123456")
        #expect(info.email == "alice@example.com" && info.isEmailVerified)
    }

    /// The token expired between being checked and being used: renewed once, not an error.
    @Test func accountCallRenewsARefusedToken() async throws {
        let auth = FakeAuth()
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        auth.reply("refresh", .success(FakeAuth.session("2", refresh: "r2")))
        let accounts = manager(auth: auth)
        try await accounts.signUpAnonymously()
        auth.refuseNextToken.withLock { $0 = true }
        _ = try await accounts.account()
        #expect(auth.calls.withLock { $0 } == ["signUpAnonymously", "account", "refresh", "account"])
        #expect(accounts.hasAccount)
    }

    @Test func passwordResetSignsIn() async throws {
        let auth = FakeAuth()
        auth.reply("requestPasswordReset", .success(nil))
        auth.reply("resetPassword", .success(FakeAuth.session("9", refresh: "r9")))
        let store = MemorySecretStore()
        let accounts = manager(store, auth: auth)
        try await accounts.requestPasswordReset(login: "alice")
        try await accounts.resetPassword(login: "alice", code: "123456", newPassword: "new password")
        #expect(store.read() == "r9")
        #expect(try await accounts.validAccessToken() == "access-9")
    }

    @Test func unreachableAuthKeepsTheAccount() async throws {
        let auth = FakeAuth()
        auth.reply("refresh", .failure(.unreachable))
        let accounts = manager(MemorySecretStore("r1"), auth: auth)
        await #expect(throws: AuthError.unreachable) {
            try await accounts.validAccessToken()
        }
        #expect(accounts.hasAccount, "a server outage is not a reason to sign out")
    }

    @Test func wrongPasswordIsReported() async throws {
        let auth = FakeAuth()
        auth.reply("logIn", .failure(.refused(code: "bad_credentials")))
        let accounts = manager(auth: auth)
        await #expect(throws: AuthError.refused(code: "bad_credentials")) {
            try await accounts.logIn(login: "alice", password: "wrong")
        }
        #expect(!accounts.hasAccount)
        #expect(authErrorText(.refused(code: "bad_credentials")) == "Wrong login or password.")
    }

    // MARK: Adding a login to an anonymous account

    /// The account stays the same: same id, the login as its name, the new
    /// session's tokens kept; asked with the anonymous session's access token.
    @Test func upgradeKeepsTheAccount() async throws {
        let store = MemorySecretStore()
        let auth = FakeAuth()
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        auth.reply("upgrade", .success(FakeAuth.upgraded("alice", refresh: "r2")))
        let accounts = manager(store, auth: auth)
        try await accounts.signUpAnonymously()
        #expect(accounts.user == AccountManager.User(id: "u1", name: "anonim1", isAnonymous: true))

        try await accounts.upgrade(login: "alice", password: "correct horse")
        #expect(accounts.user == AccountManager.User(id: "u1", name: "alice", isAnonymous: false))
        #expect(store.read() == "r2", "the old refresh token is revoked by auth: the new one is kept")
        #expect(auth.accessTokens.withLock { $0 } == ["access-1"])
        #expect(try await accounts.validAccessToken() == "access-alice")
        #expect(auth.calls.withLock { $0 } == ["signUpAnonymously", "upgrade"])
    }

    @Test func upgradeOfARegisteredAccountIsRefused() async throws {
        let store = MemorySecretStore()
        let auth = FakeAuth()
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        auth.reply("upgrade", .failure(.alreadyRegistered))
        let accounts = manager(store, auth: auth)
        try await accounts.signUpAnonymously()
        await #expect(throws: AuthError.alreadyRegistered) {
            try await accounts.upgrade(login: "alice", password: "correct horse")
        }
        #expect(store.read() == "r1" && accounts.user?.isAnonymous == true, "a refusal changes nothing here")
        #expect(authErrorText(.alreadyRegistered) == "This account already has a login. Sign in with it.")
    }

    /// Known to have a login already: refused without asking auth.
    @Test func secondUpgradeIsRefusedHere() async throws {
        let auth = FakeAuth()
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        auth.reply("upgrade", .success(FakeAuth.upgraded("alice", refresh: "r2")))
        let accounts = manager(auth: auth)
        try await accounts.signUpAnonymously()
        try await accounts.upgrade(login: "alice", password: "correct horse")
        await #expect(throws: AuthError.alreadyRegistered) {
            try await accounts.upgrade(login: "bob", password: "correct horse")
        }
        #expect(auth.calls.withLock { $0 } == ["signUpAnonymously", "upgrade"])
    }

    /// The access token expired on the way: renewed once, then asked again.
    @Test func upgradeRenewsARefusedToken() async throws {
        let store = MemorySecretStore()
        let auth = FakeAuth()
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        auth.reply("refresh", .success(FakeAuth.session("2", refresh: "r2")))
        auth.reply("upgrade", .success(FakeAuth.upgraded("alice", refresh: "r3")))
        let accounts = manager(store, auth: auth)
        try await accounts.signUpAnonymously()
        auth.refuseNextToken.withLock { $0 = true }
        try await accounts.upgrade(login: "alice", password: "correct horse")
        #expect(auth.calls.withLock { $0 } == ["signUpAnonymously", "upgrade", "refresh", "upgrade"])
        #expect(auth.accessTokens.withLock { $0 } == ["access-2"], "the refused call is not recorded")
        #expect(store.read() == "r3")
        #expect(accounts.user?.name == "alice" && accounts.user?.isAnonymous == false)
    }

    /// A renewal asked for while the login is being added must not spend the
    /// old refresh token (auth revokes it): it waits and gets the new session.
    @Test func renewalWaitsForTheUpgrade() async throws {
        let store = MemorySecretStore()
        let auth = FakeAuth(delay: .milliseconds(300))
        auth.reply("signUpAnonymously", .success(FakeAuth.session("1", refresh: "r1")))
        auth.reply("refresh", .success(FakeAuth.session("2", refresh: "r2")))
        auth.reply("upgrade", .success(FakeAuth.upgraded("alice", refresh: "r3")))
        let accounts = manager(store, auth: auth)
        try await accounts.signUpAnonymously()

        async let upgrade: Void = accounts.upgrade(login: "alice", password: "correct horse")
        try await Task.sleep(for: .milliseconds(100))
        accounts.dropAccessToken()  // As when the game server refuses the token meanwhile.
        let token = try await accounts.validAccessToken()
        try await upgrade
        #expect(token == "access-alice")
        #expect(!auth.calls.withLock { $0 }.contains("refresh"))
        #expect(store.read() == "r3")
    }

    @Test func signOutForgetsAndRevokes() async throws {
        let store = MemorySecretStore("r1")
        let auth = FakeAuth()
        auth.reply("logOut", .success(nil))
        let accounts = manager(store, auth: auth)
        await accounts.signOut()
        #expect(store.read() == nil)
        #expect(auth.calls.withLock { $0 } == ["logOut"])
    }
}
