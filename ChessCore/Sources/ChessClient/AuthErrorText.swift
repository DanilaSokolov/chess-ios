import ChessNet
import Foundation

/// What to tell the player when signing in fails, in their language. Auth
/// answers with codes (see server/internal/auth); the words are ours.
public func authErrorText(_ error: AuthError) -> String {
    switch error {
    case .unreachable:
        String(localized: "The sign-in server is not answering. Check the connection and try again.", bundle: .module)
    case .temporarilyLocked(let seconds):
        // Whole minutes, rounded up: "in 1 minute" rather than "in 0".
        String(localized: "Too many wrong passwords. Try again in \((seconds + 59) / 60) minutes.", bundle: .module)
    case .badResponse:
        String(localized: "The sign-in server sent an answer this app cannot read.", bundle: .module)
    case .alreadyRegistered:
        String(localized: "This account already has a login. Sign in with it.", bundle: .module)
    case .refused(let code):
        switch code {
        case "invalid_login":
            String(
                localized: "A login is 3 to 32 Latin letters, digits, dots, dashes or underscores.", bundle: .module)
        case "weak_password": String(localized: "The password needs at least 8 characters.", bundle: .module)
        case "login_taken": String(localized: "This login is taken. Try another one.", bundle: .module)
        case "bad_credentials": String(localized: "Wrong login or password.", bundle: .module)
        case "rate_limited": String(localized: "Too many attempts. Wait a minute and try again.", bundle: .module)
        case "invalid_token": String(localized: "You were signed out. Please sign in again.", bundle: .module)
        case "banned": String(localized: "This account is blocked.", bundle: .module)
        case "invalid_email": String(localized: "That does not look like an email address.", bundle: .module)
        case "invalid_code":
            String(localized: "The code is wrong or no longer works. Ask for a new one.", bundle: .module)
        case "email_taken": String(localized: "This email is already confirmed for another account.", bundle: .module)
        case "email_unavailable": String(localized: "Email is not available on this server.", bundle: .module)
        case "no_login": String(localized: "Anonymous accounts have no password to reset.", bundle: .module)
        case "account_locked":
            String(
                localized:
                    "Signing in with this login is locked after too many wrong passwords. Ask support to unlock it.",
                bundle: .module)
        default: String(localized: "Signing in failed (\(code)).", bundle: .module)
        }
    }
}
