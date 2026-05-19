import Foundation
import LocalAuthentication
import Security

struct KeychainTokenStore {
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<AnyObject?>?) -> OSStatus

    static let gitHubOAuthService = "StargazerBar.GitHubOAuth"
    static let legacyGitHubOAuthService = "GHMenuStars.GitHubOAuth"

    let service: String
    var copyMatching: CopyMatching = SecItemCopyMatching
    private let account = "github-oauth"

    static func gitHubOAuthStore() -> KeychainTokenStore {
        KeychainTokenStore(service: gitHubOAuthService)
    }

    static func loadGitHubOAuthToken() -> String? {
        try? gitHubOAuthStore().loadToken(allowUserInteraction: false)
    }

    static func hasGitHubOAuthToken() -> Bool {
        loadGitHubOAuthToken() != nil
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
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
        }
        var result: AnyObject?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GitHubError.transport("Keychain read failed: \(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    func hasToken() -> Bool {
        (try? loadToken(allowUserInteraction: false)) != nil
    }
}
