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

        // A private repo's stars are never fetched and are stored as 0, so a
        // star mode would render "star 0" — a number nobody looked up, about a
        // metric the repo doesn't have. Show what a private repo actually
        // measures instead: what needs attention.
        if let selected, selected.isPrivate, settings.menuBarDisplayMode.isStarMode {
            let value = selected.commitActivity.map {
                CommitActivityBuilder.total($0, since: settings.commitActivityWindow.startDate())
            }
            return MenuBarDisplayValue(
                symbolName: "chevron.left.forwardslash.chevron.right",
                text: formatted(value),
                accessibilityLabel: accessibility(
                    metric: "commits in the last \(settings.commitActivityWindow.displayName)",
                    repoName: selected.displayName,
                    value: value
                )
            )
        }

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
            // Private repos contribute nothing here: their stars were never
            // fetched, so summing their stored 0 is summing a non-measurement.
            let value = total(repos.filter { !$0.isPrivate }.map(\.lastStars))
            return MenuBarDisplayValue(
                symbolName: "star.fill",
                text: formatted(value),
                accessibilityLabel: aggregateAccessibility(
                    repos: repos,
                    metric: "GitHub stars",
                    value: value
                )
            )
        case .selectedRepoCommits:
            // The reason private repos are worth tracking at all: a number that
            // moves when you work. Read from the stored daily buckets, so
            // changing the window costs no extra API calls.
            let value = selected?.commitActivity.map {
                CommitActivityBuilder.total($0, since: settings.commitActivityWindow.startDate())
            }
            return MenuBarDisplayValue(
                symbolName: "chevron.left.forwardslash.chevron.right",
                text: formatted(value),
                accessibilityLabel: accessibility(
                    metric: "commits in the last \(settings.commitActivityWindow.displayName)",
                    repoName: selected?.displayName,
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



    /// The mode to land on when the user picks a repo for the menu bar.
    ///
    /// Selecting a repo has to *visibly* do something. Total-* modes ignore the
    /// selection entirely, so leaving one in place made the radio button look
    /// broken. And a private repo has no stars — only commits are guaranteed to
    /// be real — so a star mode there shows a number that was never fetched.
    static func modeAfterSelecting(
        isPrivate: Bool,
        current: MenuBarDisplayMode
    ) -> MenuBarDisplayMode {
        if isPrivate {
            // Downloads is respected as a deliberate choice; anything else lands
            // on commits, the one metric a private repo always has.
            return current == .selectedRepoDownloads ? current : .selectedRepoCommits
        }
        return current.requiresSelectedRepo ? current : .selectedRepoStars
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
