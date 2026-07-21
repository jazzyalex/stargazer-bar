import Foundation
import os

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

    /// Never shows keychain UI — by construction, not convention: the
    /// implementation receives only `KeychainTokenStore.SilentReader` values,
    /// a type that owns no write/delete seams, so this path cannot write,
    /// delete, or prompt. For launch polling and passive Settings refresh —
    /// a stale-ACL item reads as nil, never a prompt, and legacy-item
    /// migration is deferred to the next user-action write.
    func loadSilently() -> GitHubCredentials? {
        Self.readSilently(
            combined: combined.silentReader,
            legacyOAuth: legacyOAuth.silentReader,
            legacyPAT: legacyPAT.silentReader
        )
    }

    /// May show the keychain dialog once, then heals the item so the running
    /// build owns it. For explicit user actions only (Refresh, device-flow save,
    /// adding a private repo).
    func loadRequestingAccessIfNeeded() -> GitHubCredentials? {
        if let creds = Self.decode((try? combined.loadTokenRequestingAccessIfNeeded()) ?? nil) {
            return creds
        }
        return migrateFromLegacyInteractively()
    }

    /// Silent single-token accessors for the token-provider closures.
    func oauthSilently() -> String? { Self.trimToNil(loadSilently()?.oauth) }
    func patSilently() -> String? { Self.trimToNil(loadSilently()?.pat) }

    // MARK: - Diagnostics

    /// What the silent path sees, per keychain item, as token-free labels
    /// (found / absent / accessDenied / error). Built on `SilentReader`s only,
    /// so gathering evidence can itself never write or prompt.
    struct SilentDiagnostics: Equatable, CustomStringConvertible {
        var combined: String
        var legacyOAuth: String
        var legacyPAT: String

        var description: String {
            "combined=\(combined) legacyOAuth=\(legacyOAuth) legacyPAT=\(legacyPAT)"
        }
    }

    func silentDiagnostics() -> SilentDiagnostics {
        SilentDiagnostics(
            combined: combined.silentReader.diagnosticLabel(),
            legacyOAuth: legacyOAuth.silentReader.diagnosticLabel(),
            legacyPAT: legacyPAT.silentReader.diagnosticLabel()
        )
    }

    /// One unified-log line per launch recording what the silent credential
    /// reads saw, so a "keychain prompt on launch" report comes with evidence
    /// (`log show --predicate 'category == "Keychain"'`). Never logs token
    /// material — the labels are per-case constants.
    static func logLaunchSilentDiagnostics() {
        let diagnostics = standard().silentDiagnostics()
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "StargazerBar", category: "Keychain")
            .notice("Launch silent credential check: \(diagnostics.description, privacy: .public)")
    }

    // MARK: - Writes

    func save(_ credentials: GitHubCredentials) throws {
        guard !credentials.isEmpty else {
            try combined.deleteToken()
            return
        }
        let data = try JSONEncoder().encode(credentials)
        try combined.saveToken(String(decoding: data, as: UTF8.self))
        // Legacy retirement, gated twice:
        // 1. Only reached after `saveToken` returned without throwing — i.e.
        //    the combined write reported errSecSuccess. If it threw, the legacy
        //    items remain the only durable copy and stay untouched.
        // 2. Per slot: only delete a legacy item whose slot the just-written
        //    combined item covers. A legacy token that could not be read
        //    (stale ACL) was not carried over, so deleting it would destroy it.
        // `save` is reachable only from user-action paths (setOAuth/setPAT,
        // interactive migration) — never from `loadSilently()`.
        if credentials.oauth != nil { try? legacyOAuth.deleteToken() }
        if credentials.pat != nil { try? legacyPAT.deleteToken() }
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

    /// The entire silent path. Deliberately `static` over `SilentReader`
    /// parameters: the store's write seams are not in scope here, so a future
    /// edit cannot add a write to this path without changing its signature.
    private static func readSilently(
        combined: KeychainTokenStore.SilentReader,
        legacyOAuth: KeychainTokenStore.SilentReader,
        legacyPAT: KeychainTokenStore.SilentReader
    ) -> GitHubCredentials? {
        if let creds = decode(combined.tokenOrNil()) { return creds }
        // Combined item absent (or unreadable): fall back to the legacy items,
        // read-only. Migration to the combined item happens on the next
        // user-action write, never here.
        let creds = GitHubCredentials(
            oauth: trimToNil(legacyOAuth.tokenOrNil()),
            pat: trimToNil(legacyPAT.tokenOrNil())
        )
        return creds.isEmpty ? nil : creds
    }

    /// Reads the two legacy items and, if either holds a token, writes the
    /// combined item — which also retires the legacy items it covered, see
    /// `save(_:)`. Silent when the legacy items' ACL still trusts this build
    /// (the normal update case); otherwise prompts once — acceptable because
    /// this runs only on user-action paths. Returns nil when there is nothing
    /// to migrate. A failed combined write leaves the legacy items untouched
    /// so a later attempt can retry.
    private func migrateFromLegacyInteractively() -> GitHubCredentials? {
        let oauth = (try? legacyOAuth.loadTokenRequestingAccessIfNeeded()) ?? nil
        let pat = (try? legacyPAT.loadTokenRequestingAccessIfNeeded()) ?? nil
        let creds = GitHubCredentials(oauth: Self.trimToNil(oauth), pat: Self.trimToNil(pat))
        guard !creds.isEmpty else { return nil }
        try? save(creds)
        return creds
    }

    private static func decode(_ json: String?) -> GitHubCredentials? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GitHubCredentials.self, from: data)
    }

    private static func trimToNil(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token
    }
}

private extension KeychainTokenStore.SilentReader {
    /// Found token or nil — the silent path never distinguishes absent from
    /// access-denied when deciding what to return (both degrade to "no token").
    func tokenOrNil() -> String? {
        if case .found(let token) = ((try? outcome()) ?? .absent) { return token }
        return nil
    }
}
