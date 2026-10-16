import Foundation
import Security
import Synchronization

/// Where the refresh token lives between launches.
public protocol SecretStore: Sendable {
    func read() -> String?
    func write(_ secret: String?)
}

/// The refresh token in the Keychain, not in UserDefaults: UserDefaults is a
/// plain file in the app's container, readable from any backup; the Keychain
/// is encrypted by the system.
///
/// `AfterFirstUnlockThisDeviceOnly`: readable in the background once the
/// phone was unlocked after a restart (for reconnecting), and never moved to
/// another device by a backup, where it would be a copy of this session.
///
/// On macOS there are two keychains. The old, file-based one ties each item
/// to the code signature of the app that made it and asks "Chess wants to use
/// your confidential information" whenever another signature reads it; a
/// build signed without a team ("ad hoc") has a new signature after every
/// rebuild, so it asks again and again. The newer data protection keychain
/// (the only one on iOS) asks nothing, but needs an app signed with a team.
/// So on macOS: the data protection keychain when the app is signed with a
/// team; for a debug build without one, a file in the app's sandbox container
/// instead (other apps cannot read it without the user's consent); never the
/// old keychain, except to move a token it already holds.
public struct KeychainSecretStore: SecretStore {
    let service: String
    let account: String

    public init(service: String = "dev.chess.Chess.auth", account: String = "refresh-token") {
        self.service = service
        self.account = account
    }

    private enum Backend: Sendable {
        case dataProtectionKeychain
        /// The old keychain: only a release build without a team gets here.
        case legacyKeychain
        /// A debug build without a team, on macOS.
        case file
    }

    /// Decided once per launch, by asking the data protection keychain: a
    /// build without a team gets errSecMissingEntitlement.
    private static let backend: Backend = {
        #if os(macOS)
            var q = baseQuery(service: "dev.chess.Chess.probe", account: "probe")
            q[kSecUseDataProtectionKeychain as String] = true
            guard SecItemCopyMatching(q as CFDictionary, nil) == errSecMissingEntitlement else {
                return .dataProtectionKeychain
            }
            #if DEBUG
                return .file
            #else
                return .legacyKeychain
            #endif
        #else
            return .dataProtectionKeychain
        #endif
    }()

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func query(dataProtection: Bool) -> [String: Any] {
        var q = Self.baseQuery(service: service, account: account)
        if dataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }

    public func read() -> String? {
        let stored: String? =
            switch Self.backend {
            case .dataProtectionKeychain: readKeychain(dataProtection: true)
            case .legacyKeychain: readKeychain(dataProtection: false)
            case .file: readFile()
            }
        if let stored { return stored }
        #if os(macOS)
            // Signed with a team now, after debug builds kept the token in a file: move it.
            if Self.backend == .dataProtectionKeychain, let fromFile = readFile() {
                write(fromFile)
                writeFile(nil)
                return fromFile
            }
            // A token saved by an earlier version in the old keychain: moved
            // once (this read may ask the user one last time), then removed there.
            if Self.backend != .legacyKeychain, let old = readKeychain(dataProtection: false) {
                write(old)
                SecItemDelete(query(dataProtection: false) as CFDictionary)
                return old
            }
        #endif
        return nil
    }

    public func write(_ secret: String?) {
        switch Self.backend {
        case .dataProtectionKeychain: writeKeychain(secret, dataProtection: true)
        case .legacyKeychain: writeKeychain(secret, dataProtection: false)
        case .file: writeFile(secret)
        }
    }

    private func readKeychain(dataProtection: Bool) -> String? {
        var q = query(dataProtection: dataProtection)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ secret: String?, dataProtection: Bool) {
        SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
        guard let secret else { return }
        var q = query(dataProtection: dataProtection)
        q[kSecValueData as String] = Data(secret.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    /// Application Support inside the sandbox: ~/Library/Containers/<bundle id>/...
    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: service, directoryHint: .isDirectory)
            .appending(path: account)
    }

    private func readFile() -> String? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeFile(_ secret: String?) {
        guard let url = fileURL else { return }
        guard let secret else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Readable by this user only; atomic, so a crash never leaves half a token.
        try? Data(secret.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// For tests and previews: forgets everything when released.
public final class MemorySecretStore: SecretStore {
    private let secret: Mutex<String?>

    public init(_ secret: String? = nil) { self.secret = Mutex(secret) }

    public func read() -> String? { secret.withLock { $0 } }
    public func write(_ secret: String?) { self.secret.withLock { $0 = secret } }
}
