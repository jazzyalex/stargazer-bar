import Foundation

enum RefreshInterval: String, Codable, CaseIterable, Identifiable {
    case tenMinutes
    case sixtyMinutes
    case oneDay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tenMinutes: return "10 min"
        case .sixtyMinutes: return "60 min"
        case .oneDay: return "1 day"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .tenMinutes: return 10 * 60
        case .sixtyMinutes: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }
}

