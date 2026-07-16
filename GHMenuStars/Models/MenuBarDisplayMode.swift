import Foundation

enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case selectedRepoStars
    case selectedRepoDownloads
    case totalStars
    case totalDownloads
    case selectedRepoCommits
    case selectedRepoNeedsMe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selectedRepoStars:
            return "Selected repo stars"
        case .selectedRepoDownloads:
            return "Selected repo downloads"
        case .totalStars:
            return "Total stars"
        case .totalDownloads:
            return "Total downloads"
        case .selectedRepoCommits:
            return "Selected repo commits"
        case .selectedRepoNeedsMe:
            return "Selected repo needs me"
        }
    }

    /// Star-shaped modes have no meaning for a private repo, whose stars are
    /// never fetched.
    var isStarMode: Bool {
        switch self {
        case .selectedRepoStars, .totalStars:
            return true
        case .selectedRepoDownloads, .totalDownloads, .selectedRepoCommits, .selectedRepoNeedsMe:
            return false
        }
    }

    var requiresSelectedRepo: Bool {
        switch self {
        case .selectedRepoStars, .selectedRepoDownloads, .selectedRepoCommits, .selectedRepoNeedsMe:
            return true
        case .totalStars, .totalDownloads:
            return false
        }
    }
}
