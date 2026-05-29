import Foundation

struct MenuBarDisplayValue: Equatable {
    var symbolName: String
    var text: String
    var accessibilityLabel: String
}

enum MenuBarDisplayResolver {
    static func value(
        repos: [TrackedRepo],
        settings: AppSettings
    ) -> MenuBarDisplayValue {
        let selected = selectedRepo(in: repos, id: settings.selectedMenuBarRepoID)
        switch settings.menuBarDisplayMode {
        case .selectedRepoStars:
            let value = selected?.lastStars
            return MenuBarDisplayValue(
                symbolName: "star.fill",
                text: formatted(value),
                accessibilityLabel: accessibility(
                    metric: "stars",
                    repoName: selected?.displayName,
                    value: value
                )
            )
        case .selectedRepoDownloads:
            let value = selected?.lastDownloads
            return MenuBarDisplayValue(
                symbolName: "arrow.down.circle.fill",
                text: formatted(value),
                accessibilityLabel: accessibility(
                    metric: "release downloads",
                    repoName: selected?.displayName,
                    value: value
                )
            )
        case .totalStars:
            let value = total(repos.map(\.lastStars))
            return MenuBarDisplayValue(
                symbolName: "star.fill",
                text: formatted(value),
                accessibilityLabel: aggregateAccessibility(
                    repos: repos,
                    metric: "GitHub stars",
                    value: value
                )
            )
        case .totalDownloads:
            let value = total(repos.map(\.lastDownloads))
            return MenuBarDisplayValue(
                symbolName: "arrow.down.circle.fill",
                text: formatted(value),
                accessibilityLabel: aggregateAccessibility(
                    repos: repos,
                    metric: "release downloads",
                    value: value
                )
            )
        }
    }

    static func selectedRepo(in repos: [TrackedRepo], id: UUID?) -> TrackedRepo? {
        guard let id else { return repos.first }
        return repos.first { $0.id == id } ?? repos.first
    }

    private static func formatted(_ value: Int?) -> String {
        guard let value else { return "--" }
        return NumberFormatter.menuInteger.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func total(_ values: [Int?]) -> Int? {
        let knownValues = values.compactMap { $0 }
        guard !knownValues.isEmpty else { return nil }
        return knownValues.reduce(0, +)
    }

    private static func aggregateAccessibility(repos: [TrackedRepo], metric: String, value: Int?) -> String {
        if repos.isEmpty { return "No repositories configured" }
        guard let value else { return "Total \(metric) not checked yet" }
        return "Total \(metric) \(value)"
    }

    private static func accessibility(metric: String, repoName: String?, value: Int?) -> String {
        guard let repoName, let value else { return "GitHub \(metric) not configured" }
        return "\(repoName) GitHub \(metric) \(value)"
    }
}
