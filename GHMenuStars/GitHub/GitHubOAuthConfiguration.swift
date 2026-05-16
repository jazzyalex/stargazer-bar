import Foundation

enum GitHubOAuthConfiguration {
    static func clientID(
        settings: AppSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionaryClientID: String? = Bundle.main.object(forInfoDictionaryKey: "GHMenuStarsGitHubOAuthClientID") as? String
    ) -> String? {
        let configured = [
            environment["GH_MENU_STARS_GITHUB_CLIENT_ID"],
            infoDictionaryClientID,
            settings.gitHubOAuthClientID
        ]

        return configured
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.contains("$(") }
    }
}
