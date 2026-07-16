import Foundation

/// The user's browsable GitHub repositories (public + private), cached so
/// Settings can show them instantly on open and refresh silently in the
/// background. This is display data for the picker — the source of truth for
/// tracked repos remains TrackedRepoStore.
struct RepoDirectory: Codable, Equatable {
    var repos: [GitHubRepoSummary]
    var login: String?
    var lastRefreshed: Date?

    static let empty = RepoDirectory(repos: [], login: nil, lastRefreshed: nil)
}

/// Persists the repo directory in UserDefaults, following the same convention
/// as TrackedRepoStore (JSON under a versioned key, corrupt data tolerated).
enum RepoDirectoryStore {
    static let key = "GHMenuStars.RepoDirectory.v1"

    static func load(defaults: UserDefaults = .standard) -> RepoDirectory? {
        guard let data = defaults.data(forKey: key) else { return nil }
        // A decode failure (schema drift, corruption) degrades to "no cache"
        // rather than crashing — the next refresh repopulates it.
        return try? JSONDecoder().decode(RepoDirectory.self, from: data)
    }

    static func save(_ directory: RepoDirectory, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(directory) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
