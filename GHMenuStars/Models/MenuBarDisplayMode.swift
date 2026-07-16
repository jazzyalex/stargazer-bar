import Foundation

enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case selectedRepoStars
    case selectedRepoDownloads
    case totalStars
    case totalDownloads

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
        }
    }

    /// Star-shaped modes have no meaning for a private repo, whose stars are
    /// never fetched.
    var isStarMode: Bool {
        switch self {
        case .selectedRepoStars, .totalStars:
            return true
        case .selectedRepoDownloads, .totalDownloads:
            return false
        }
    }

    var requiresSelectedRepo: Bool {
        switch self {
        case .selectedRepoStars, .selectedRepoDownloads:
            return true
        case .totalStars, .totalDownloads:
            return false
        }
    }
}
