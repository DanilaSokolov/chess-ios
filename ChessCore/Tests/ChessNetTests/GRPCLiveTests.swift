import ChessCore
import Foundation
import Testing

@testable import ChessNet

/// The gRPC services, live: the game server's GameInfo and Health, and the
/// auth service. Skipped unless the addresses are set:
///
///     docker compose up -d
///     CHESS_SERVER_URL=ws://localhost:8080/ws CHESS_AUTH_URL=http://localhost:8081 swift test
let liveAuthURL = ProcessInfo.processInfo.environment["CHESS_AUTH_URL"].flatMap(URL.init(string:))

@Suite(.enabled(if: liveServerURL != nil))
struct GameInfoLiveTests {
    @Test func bootstrapAnswers() async throws {
        let b = try #require(
            await Bootstrap.fetch(from: liveServerURL!, clientVersion: "0.1", language: "ru", timeout: .seconds(3)))
        #expect(b.client.status == .supported)
        #expect(!b.lobbyTimeControls.isEmpty)
    }

    @Test func healthIsServing() async {
        #expect(await ServerHealth.check(liveServerURL!) != nil)
    }
}

@Suite(.enabled(if: liveAuthURL != nil))
struct AuthLiveTests {
    let auth = AuthClient(url: liveAuthURL ?? URL(string: "http://localhost")!)!

    @Test func anonymousSignUpAndRefresh() async throws {
        let first = try await auth.signUpAnonymously()
        #expect(first.anonymous && first.name.hasPrefix("anonim") && first.expiresIn > 0)
        let second = try await auth.refresh(first.refreshToken)
        #expect(second.userID == first.userID && second.refreshToken != first.refreshToken)
        // The first token again: a stolen copy. Refused, and the reason comes through ErrorInfo.
        await #expect(throws: AuthError.refused(code: "invalid_token")) {
            try await auth.refresh(first.refreshToken)
        }
    }

    @Test func registerThenLogIn() async throws {
        let login = "swift" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let created = try await auth.register(login: login, password: "correct horse", email: "")
        #expect(created.name == login && !created.anonymous)
        await #expect(throws: AuthError.refused(code: "login_taken")) {
            try await auth.register(login: login, password: "another one", email: "")
        }
        let session = try await auth.logIn(login: login, password: "correct horse")
        #expect(session.userID == created.userID)
        await #expect(throws: AuthError.refused(code: "bad_credentials")) {
            try await auth.logIn(login: login, password: "wrong password")
        }
        try await auth.logOut(session.refreshToken)
    }

    /// A login added to an anonymous account: the same user, a new session,
    /// the old refresh token revoked; a second time is refused with its reason.
    @Test func loginAddedToAnonymousAccount() async throws {
        let anonymous = try await auth.signUpAnonymously()
        let login = "link" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let linked = try await auth.register(
            login: login, password: "correct horse", email: "", accessToken: anonymous.accessToken)
        #expect(linked.userID == anonymous.userID && linked.name == login && !linked.anonymous)
        #expect(linked.refreshToken != anonymous.refreshToken)
        await #expect(throws: AuthError.alreadyRegistered) {
            try await auth.register(
                login: login + "x", password: "correct horse", email: "", accessToken: linked.accessToken)
        }
        // Last: a revoked token presented again may revoke the new session too, as a theft.
        await #expect(throws: AuthError.self) {
            try await auth.refresh(anonymous.refreshToken)
        }
        let session = try await auth.logIn(login: login, password: "correct horse")
        #expect(session.userID == anonymous.userID)
        try await auth.logOut(session.refreshToken)
    }

    /// Three wrong passwords lock signing in; the lock and its length come
    /// through google.rpc.ErrorInfo.
    @Test func wrongPasswordsLockTheLogin() async throws {
        let login = "lock" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
        _ = try await auth.register(login: login, password: "correct horse", email: "")
        for _ in 1...2 {
            await #expect(throws: AuthError.refused(code: "bad_credentials")) {
                try await auth.logIn(login: login, password: "wrong pass")
            }
        }
        do {
            _ = try await auth.logIn(login: login, password: "wrong pass")
            Issue.record("third wrong password was let through")
        } catch .temporarilyLocked(let seconds) {
            #expect((899...900).contains(seconds))
        } catch {
            Issue.record("third wrong password: \(error)")
        }
    }

    @Test func nobodyListeningIsUnreachable() async {
        let nowhere = AuthClient(endpoint: GRPCEndpoint(host: "127.0.0.1", port: 9, usesTLS: false))
        await #expect(throws: AuthError.unreachable) {
            try await nowhere.signUpAnonymously()
        }
    }
}

let liveHistoryURL = ProcessInfo.processInfo.environment["CHESS_HISTORY_URL"].flatMap(URL.init(string:))

@Suite(.enabled(if: liveAuthURL != nil && liveHistoryURL != nil))
struct HistoryLiveTests {
    let auth = AuthClient(url: liveAuthURL ?? URL(string: "http://localhost")!)!
    let history = HistoryClient(url: liveHistoryURL ?? URL(string: "http://localhost")!)!

    /// A brand-new account has no games, and asks with a real token from auth.
    @Test func newAccountHasNoGames() async throws {
        let session = try await auth.signUpAnonymously()
        let summary = try await history.summary(accessToken: session.accessToken)
        #expect(summary == HistorySummary(games: 0, wins: 0, losses: 0, draws: 0))
        let page = try await history.games(pageToken: nil, pageSize: 20, accessToken: session.accessToken)
        #expect(page.entries.isEmpty && page.nextPageToken == nil)
        await #expect(throws: HistoryError.notFound) {
            try await history.game(id: "no-such-game", accessToken: session.accessToken)
        }
    }

    @Test func forgedTokenIsRefused() async {
        await #expect(throws: HistoryError.unauthenticated) {
            try await history.summary(accessToken: "header.claims.signature")
        }
    }
}

let liveMailpitURL = ProcessInfo.processInfo.environment["CHESS_MAILPIT_URL"].flatMap(URL.init(string:))

/// Email and password reset end to end: auth sends real emails to Mailpit,
/// and the test reads the codes from Mailpit's API, as a player would read them.
@Suite(.enabled(if: liveAuthURL != nil && liveMailpitURL != nil))
struct EmailLiveTests {
    let auth = AuthClient(url: liveAuthURL ?? URL(string: "http://localhost")!)!

    /// The 6-digit code in the latest email to `address`.
    func code(sentTo address: String) async throws -> String {
        struct Search: Decodable {
            struct Message: Decodable {
                let subject: String
                // Mailpit's API names its fields in UpperCamelCase.
                enum CodingKeys: String, CodingKey { case subject = "Subject" }
            }
            let messages: [Message]
        }
        var search = URLComponents(
            url: liveMailpitURL!.appending(path: "api/v1/search"), resolvingAgainstBaseURL: false)!
        search.queryItems = [URLQueryItem(name: "query", value: "to:\(address)")]
        for _ in 0..<50 {
            let (data, _) = try await URLSession.shared.data(from: search.url!)
            if let subject = try JSONDecoder().decode(Search.self, from: data).messages.first?.subject,
                let match = subject.firstMatch(of: /\d{6}/)
            {
                return String(match.output)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }

    @Test func confirmEmailThenResetPassword() async throws {
        let login = "reset" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let email = "\(login)@example.com"
        let created = try await auth.register(login: login, password: "old password", email: email)

        let confirmed = try await auth.verifyEmail(
            code: try await code(sentTo: email), accessToken: created.accessToken)
        #expect(confirmed.email == email && confirmed.isEmailVerified)

        try await auth.requestPasswordReset(login: login)
        // The reset email is the newer one; wait for its code to differ from the confirmation's.
        let confirmation = try await code(sentTo: email)
        var resetCode = confirmation
        for _ in 0..<50 where resetCode == confirmation {
            try await Task.sleep(for: .milliseconds(100))
            resetCode = try await code(sentTo: email)
        }
        let session = try await auth.resetPassword(login: login, code: resetCode, newPassword: "new password")
        #expect(session.userID == created.userID)
        _ = try await auth.logIn(login: login, password: "new password")
        await #expect(throws: AuthError.refused(code: "bad_credentials")) {
            try await auth.logIn(login: login, password: "old password")
        }
        // Resetting ended the old session.
        await #expect(throws: AuthError.refused(code: "invalid_token")) {
            try await auth.refresh(created.refreshToken)
        }
    }
}
