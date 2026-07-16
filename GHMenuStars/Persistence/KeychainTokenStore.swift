import Foundation
import LocalAuthentication
import Security

struct KeychainTokenStore {
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    typealias UpdateItem = (CFDictionary, CFDictionary) -> OSStatus
    typealias AddItem = (CFDictionary) -> OSStatus
    typealias DeleteItem = (CFDictionary) -> OSStatus

    static let gitHubOAuthService = "StargazerBar.GitHubOAuth"
    static let legacyGitHubOAuthService = "GHMenuStars.GitHubOAuth"
    static let gitHubPATService = "StargazerBar.GitHubPAT"

    /// Serializes keychain access so a silent read (which flips the
    /// process-global interaction switch off) can never race an interactive
    /// read into silence.
    private static let interactionLock = NSLock()
    /// Guards `interactiveReadsInFlight` and `lastKnownTokens`.
    private static let stateLock = NSLock()
    /// Non-zero while an interactive read may be showing the keychain password
    /// dialog — i.e. while `interactionLock` can be held for minutes, not
    /// milliseconds. Silent readers check this instead of blocking behind it.
    private static var interactiveReadsInFlight = 0
    /// Last token each (service, account) successfully read or saved, so
    /// silent readers stay truthful while the dialog blocks the keychain.
    private static var lastKnownTokens: [String: String] = [:]

    let service: String
    // Declared before `copyMatching` so the synthesized memberwise init keeps
    // `copyMatching` last and trailing-closure call sites still bind to it.
    // A `var` with a default rather than a `let`: a `let` with an initial value
    // is excluded from the memberwise init entirely.
    var account: String = "github-oauth"
    var updateItem: UpdateItem = { SecItemUpdate($0, $1) }
    var addItem: AddItem = { SecItemAdd($0, nil) }
    var deleteItem: DeleteItem = { SecItemDelete($0) }
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
        let updateStatus = updateItem(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            rememberLastKnownToken(token)
            return
        }
        switch updateStatus {
        case errSecItemNotFound:
            break
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            // The existing item's ACL no longer trusts this binary (typical
            // after an update), so it can't be updated in place — and it
            // couldn't be read either, so deleting it loses nothing. Recreate
            // it owned by the running app.
            _ = deleteItem(query as CFDictionary)
        default:
            throw GitHubError.transport("Keychain update failed: \(updateStatus)")
        }

        var add = query
        add[kSecValueData as String] = data
        let status = addItem(add as CFDictionary)
        guard status == errSecSuccess else { throw GitHubError.transport("Keychain save failed: \(status)") }
        rememberLastKnownToken(token)
    }

    /// Outcome of a read that is guaranteed to never show keychain UI.
    enum SilentLoadOutcome: Equatable {
        case found(String)
        case absent
        /// The item exists but macOS would need to show the password dialog to
        /// release it — the item's ACL doesn't trust this binary (post-update
        /// signature change, or a token created by a differently-signed build).
        case accessDenied
    }

    func loadToken(allowUserInteraction: Bool = true) throws -> String? {
        guard allowUserInteraction else {
            switch try silentLoadOutcome() {
            case .found(let token): return token
            case .absent, .accessDenied: return nil
            }
        }

        // Announce the possible dialog before taking the lock, so silent
        // readers arriving mid-dialog serve the cache instead of queueing
        // behind a prompt the user may stare at for minutes.
        Self.stateLock.lock()
        Self.interactiveReadsInFlight += 1
        Self.stateLock.unlock()
        Self.interactionLock.lock()
        defer {
            Self.interactionLock.unlock()
            Self.stateLock.lock()
            Self.interactiveReadsInFlight -= 1
            Self.stateLock.unlock()
        }
        var result: AnyObject?
        let status = copyMatching(baseReadQuery() as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            forgetLastKnownToken()
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            // The user dismissed or failed the password dialog. That's "I can't
            // unlock the old token", not an app error — callers fall through to
            // re-authentication.
            return nil
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw GitHubError.transport("Keychain read failed: \(status)")
            }
            rememberLastKnownToken(token)
            return token
        default:
            throw GitHubError.transport("Keychain read failed: \(status)")
        }
    }

    /// A read that never shows UI, and reports *why* there was no token.
    ///
    /// The LAContext/kSecUseAuthenticationUISkip flags below do NOT silence the
    /// file-based keychain's ACL password dialog — SecItemCopyMatching still
    /// blocks on it (verified on macOS 15). The only switch that actually works
    /// for the login keychain is the process-global one, so the read is
    /// bracketed by SecKeychainSetUserInteractionAllowed under a lock.
    func silentLoadOutcome() throws -> SilentLoadOutcome {
        var query = baseReadQuery()
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        // If an interactive read may be mid-dialog, don't queue behind a
        // prompt the user could stare at for minutes — serve the last token
        // this store successfully read. Contention with other *silent* reads
        // is not an exit condition: those hold the lock for microseconds, so
        // blocking is correct and never turns a stored token into a false nil.
        Self.stateLock.lock()
        let dialogMayBeUp = Self.interactiveReadsInFlight > 0
        let lastKnown = Self.lastKnownTokens[lastKnownKey]
        Self.stateLock.unlock()
        if dialogMayBeUp {
            if let lastKnown { return .found(lastKnown) }
            return .accessDenied
        }

        Self.interactionLock.lock()
        SecKeychainSetUserInteractionAllowed(false)
        defer {
            SecKeychainSetUserInteractionAllowed(true)
            Self.interactionLock.unlock()
        }

        var result: AnyObject?
        let status = copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            forgetLastKnownToken()
            return .absent
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .accessDenied
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw GitHubError.transport("Keychain read failed: \(status)")
            }
            rememberLastKnownToken(token)
            return .found(token)
        default:
            throw GitHubError.transport("Keychain read failed: \(status)")
        }
    }

    private var lastKnownKey: String {
        service + "\u{1F}" + account
    }

    private func rememberLastKnownToken(_ token: String) {
        Self.stateLock.lock()
        Self.lastKnownTokens[lastKnownKey] = token
        Self.stateLock.unlock()
    }

    private func forgetLastKnownToken() {
        Self.stateLock.lock()
        Self.lastKnownTokens[lastKnownKey] = nil
        Self.stateLock.unlock()
    }

    /// For user-initiated actions only: reads silently when possible, and when
    /// the item's ACL no longer trusts this binary, shows the password dialog
    /// once and then recreates the item so the running app owns it — one prompt
    /// per update at most, instead of one per launch forever.
    func loadTokenRequestingAccessIfNeeded() throws -> String? {
        switch try silentLoadOutcome() {
        case .found(let token):
            return token
        case .absent:
            return nil
        case .accessDenied:
            guard let token = try loadToken(allowUserInteraction: true) else { return nil }
            // SecItemUpdate on the untrusted item would raise a second dialog,
            // so heal via delete + add. Best-effort: the token in hand is what
            // the caller needed; a failed rewrite just means one more prompt
            // next time.
            try? deleteToken()
            try? saveToken(token)
            return token
        }
    }

    func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = deleteItem(query as CFDictionary)
        // Already absent is success: removing a token that isn't there is the
        // state the caller wanted.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubError.transport("Keychain delete failed: \(status)")
        }
        forgetLastKnownToken()
    }

    func hasToken() -> Bool {
        (try? loadToken(allowUserInteraction: false)) != nil
    }

    private func baseReadQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }
}
