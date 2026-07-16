import Foundation
import LocalAuthentication
import Security

struct KeychainTokenStore {
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<AnyObject?>?) -> OSStatus

    static let gitHubOAuthService = "StargazerBar.GitHubOAuth"
    static let legacyGitHubOAuthService = "GHMenuStars.GitHubOAuth"
    static let gitHubPATService = "StargazerBar.GitHubPAT"

    let service: String
    // Declared before `copyMatching` so the synthesized memberwise init keeps
    // `copyMatching` last and trailing-closure call sites still bind to it.
    // A `var` with a default rather than a `let`: a `let` with an initial value
    // is excluded from the memberwise init entirely.
    var account: String = "github-oauth"
    var copyMatching: CopyMatching = SecItemCopyMatching

    static func gitHubOAuthStore() -> KeychainTokenStore {
        KeychainTokenStore(service: gitHubOAuthService)
    }

    /// The fine-grained PAT that reaches private repos. Kept under its own
    /// (service, account) pair — the Keychain primary key — so it can never be
    /// read back as an OAuth token, and so revoking one leaves the other intact.
    static func gitHubPATStore() -> KeychainTokenStore {
        KeychainTokenStore(service: gitHubPATService, account: "github-pat")
    }

    static func loadGitHubOAuthToken() -> String? {
        try? gitHubOAuthStore().loadToken(allowUserInteraction: false)
    }

    static func hasGitHubOAuthToken() -> Bool {
        loadGitHubOAuthToken() != nil
    }

    static func loadGitHubPAT() -> String? {
        try? gitHubPATStore().loadToken(allowUserInteraction: false)
    }

    static func hasGitHubPAT() -> Bool {
        loadGitHubPAT() != nil
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Update in place when an item exists. The previous delete-then-add left
        // the user with no token at all if the add failed — destroying a working
        // credential to store one that never landed.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GitHubError.transport("Keychain update failed: \(updateStatus)")
        }

        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitHubError.transport("Keychain save failed: \(status)") }
    }

    func loadToken(allowUserInteraction: Bool = true) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var result: AnyObject?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GitHubError.transport("Keychain read failed: \(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Already absent is success: removing a token that isn't there is the
        // state the caller wanted.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubError.transport("Keychain delete failed: \(status)")
        }
    }

    func hasToken() -> Bool {
        (try? loadToken(allowUserInteraction: false)) != nil
    }
}
