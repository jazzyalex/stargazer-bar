import Foundation

/// Both GitHub tokens the app stores: the OAuth token (public scope) and the
/// fine-grained PAT that reaches private repos.
struct GitHubCredentials: Codable, Equatable {
    var oauth: String?
    var pat: String?

    var isEmpty: Bool {
        (oauth?.isEmpty ?? true) && (pat?.isEmpty ?? true)
    }
}

/// One keychain item holding both tokens, replacing the two legacy single-token
/// items. One item means at most one keychain prompt instead of two, and — once
/// created by a properly signed build — it reads silently across same-identity
/// app updates (verified spike, see
/// docs/superpowers/specs/2026-07-16-repository-settings-redesign.md). No custom
/// SecAccess/partition-list code is needed; plain SecItemAdd from a signed build
/// is sufficient, so this composes the existing KeychainTokenStore rather than
/// re-implementing keychain access.
struct GitHubCredentialStore {
    static let service = "StargazerBar.GitHubCredentials"
    static let account = "github"

    /// The combined item. Legacy stores exist only to migrate old installs.
    var combined: KeychainTokenStore
    var legacyOAuth: KeychainTokenStore
    var legacyPAT: KeychainTokenStore

    init(
        combined: KeychainTokenStore = KeychainTokenStore(
            service: GitHubCredentialStore.service,
            account: GitHubCredentialStore.account
        ),
        legacyOAuth: KeychainTokenStore = KeychainTokenStore.gitHubOAuthStore(),
        legacyPAT: KeychainTokenStore = KeychainTokenStore.gitHubPATStore()
    ) {
        self.combined = combined
        self.legacyOAuth = legacyOAuth
        self.legacyPAT = legacyPAT
    }

    static func standard() -> GitHubCredentialStore { GitHubCredentialStore() }

    /// Silent static conveniences for token-provider closures (launch polling).
    static func loadOAuthTokenSilently() -> String? { standard().oauthSilently() }
    static func loadPATSilently() -> String? { standard().patSilently() }
    static func hasOAuthTokenSilently() -> Bool { loadOAuthTokenSilently() != nil }

    // MARK: - Reads

    /// Never shows keychain UI. For launch polling and passive Settings refresh —
    /// a stale-ACL item reads as nil, never a prompt.
    func loadSilently() -> GitHubCredentials? {
        if let creds = readCombined(interactive: false) { return creds }
        return migrateFromLegacy(interactive: false)
    }

    /// May show the keychain dialog once, then heals the item so the running
    /// build owns it. For explicit user actions only (Refresh, device-flow save,
    /// adding a private repo).
    func loadRequestingAccessIfNeeded() -> GitHubCredentials? {
        if let creds = readCombined(interactive: true) { return creds }
        return migrateFromLegacy(interactive: true)
    }

    /// Silent single-token accessors for the token-provider closures.
    func oauthSilently() -> String? { Self.trimToNil(loadSilently()?.oauth) }
    func patSilently() -> String? { Self.trimToNil(loadSilently()?.pat) }

    // MARK: - Writes

    func save(_ credentials: GitHubCredentials) throws {
        guard !credentials.isEmpty else {
            try combined.deleteToken()
            return
        }
        let data = try JSONEncoder().encode(credentials)
        try combined.saveToken(String(decoding: data, as: UTF8.self))
    }

    /// Set the OAuth token while preserving any stored PAT.
    func setOAuth(_ token: String?) throws {
        var creds = loadSilently() ?? GitHubCredentials()
        creds.oauth = Self.trimToNil(token)
        try save(creds)
    }

    /// Set the PAT while preserving the stored OAuth token.
    func setPAT(_ token: String?) throws {
        var creds = loadSilently() ?? GitHubCredentials()
        creds.pat = Self.trimToNil(token)
        try save(creds)
    }

    func clearPAT() throws { try setPAT(nil) }

    // MARK: - Internals

    private func readCombined(interactive: Bool) -> GitHubCredentials? {
        let json: String?
        if interactive {
            json = (try? combined.loadTokenRequestingAccessIfNeeded()) ?? nil
        } else {
            json = (try? combined.loadToken(allowUserInteraction: false)) ?? nil
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GitHubCredentials.self, from: data)
    }

    /// Reads the two legacy items and, if either holds a token, writes the
    /// combined item and deletes the legacy pair — a one-time migration. Silent
    /// when the legacy items' ACL still trusts this build (the normal update
    /// case); otherwise prompts once on the interactive path. Returns nil when
    /// there is nothing to migrate.
    @discardableResult
    private func migrateFromLegacy(interactive: Bool) -> GitHubCredentials? {
        let oauth: String?
        let pat: String?
        if interactive {
            oauth = (try? legacyOAuth.loadTokenRequestingAccessIfNeeded()) ?? nil
            pat = (try? legacyPAT.loadTokenRequestingAccessIfNeeded()) ?? nil
        } else {
            oauth = (try? legacyOAuth.loadToken(allowUserInteraction: false)) ?? nil
            pat = (try? legacyPAT.loadToken(allowUserInteraction: false)) ?? nil
        }
        let creds = GitHubCredentials(oauth: Self.trimToNil(oauth), pat: Self.trimToNil(pat))
        guard !creds.isEmpty else { return nil }
        try? save(creds)
        try? legacyOAuth.deleteToken()
        try? legacyPAT.deleteToken()
        return creds
    }

    private static func trimToNil(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token
    }
}
