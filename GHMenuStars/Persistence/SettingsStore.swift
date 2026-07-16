import Combine
import CoreGraphics
import Foundation

enum CelebrationMode: String, Codable, CaseIterable, Identifiable {
    case off
    case subtle
    case fun

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .fun: return "Fun"
        }
    }

    var pulseDuration: UInt64 {
        switch self {
        case .off: return 0
        case .subtle: return 1_200_000_000
        case .fun: return 1_800_000_000
        }
    }

    var pulseScale: Double {
        switch self {
        case .off: return 1.0
        case .subtle: return 1.06
        case .fun: return 1.14
        }
    }

    var glowRadius: CGFloat {
        switch self {
        case .off: return 0
        case .subtle: return 3
        case .fun: return 7
        }
    }
}

enum RepoTrendRange: String, Codable, CaseIterable, Identifiable {
    case all
    case twelveMonths
    case oneMonth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .twelveMonths: return "12 Months"
        case .oneMonth: return "1 Month"
        }
    }

    var chartTitle: String {
        switch self {
        case .all: return "All time"
        case .twelveMonths: return "Last 12 months"
        case .oneMonth: return "Last 30 days"
        }
    }

    var axisLabel: String {
        switch self {
        case .all: return "all"
        case .twelveMonths: return "1y"
        case .oneMonth: return "1m"
        }
    }

    func startDate(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .all:
            return nil
        case .twelveMonths:
            return calendar.date(byAdding: .day, value: -365, to: now) ?? now.addingTimeInterval(-365 * 86_400)
        case .oneMonth:
            return calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 86_400)
        }
    }
}

enum MaintainerRadarActivityWindow: String, Codable, CaseIterable, Identifiable {
    case off
    case oneHour
    case oneDay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .oneHour: return "1 Hour"
        case .oneDay: return "24 Hours"
        }
    }

    var menuLabel: String {
        switch self {
        case .off: return ""
        case .oneHour: return "last hour"
        case .oneDay: return "last 24h"
        }
    }

    func startDate(now: Date = Date()) -> Date? {
        switch self {
        case .off:
            return nil
        case .oneHour:
            return now.addingTimeInterval(-3_600)
        case .oneDay:
            return now.addingTimeInterval(-86_400)
        }
    }
}

/// How far back the menu bar's commit counter looks.
///
/// Cheap to change: the poll stores 30 days of daily buckets, so every window
/// here is a filter over data already fetched — no extra API calls.
enum CommitActivityWindow: String, Codable, CaseIterable, Identifiable {
    case oneDay
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneDay: return "24 Hours"
        case .sevenDays: return "7 Days"
        case .thirtyDays: return "30 Days"
        }
    }

    var shortLabel: String {
        switch self {
        case .oneDay: return "24h"
        case .sevenDays: return "7d"
        case .thirtyDays: return "30d"
        }
    }

    func startDate(now: Date = Date()) -> Date {
        switch self {
        case .oneDay: return now.addingTimeInterval(-86_400)
        case .sevenDays: return now.addingTimeInterval(-7 * 86_400)
        case .thirtyDays: return now.addingTimeInterval(-30 * 86_400)
        }
    }
}

struct AppSettings: Codable, Equatable {
    var refreshInterval: RefreshInterval = .tenMinutes
    var hideDockIcon: Bool = true
    var notifyOnStarIncrease: Bool = true
    var playSoundOnStarIncrease: Bool = false
    var starSoundThreshold: StarSoundThreshold = .one
    var animateOnStarIncrease: Bool = true
    var celebrationMode: CelebrationMode = .subtle
    var isMuted: Bool = false
    var gitHubOAuthClientID: String = ""
    var menuBarDisplayMode: MenuBarDisplayMode = .selectedRepoStars
    var selectedMenuBarRepoID: UUID?
    var repoTrendRange: RepoTrendRange = .all
    var maintainerRadarActivityWindow: MaintainerRadarActivityWindow = .oneDay
    /// Whether a private-repo token is stored. Presence is not a secret, and
    /// keeping it here means the UI never reads the Keychain just to decide
    /// whether to show a Remove button — that read prompts for a password.
    var hasPrivateRepoToken: Bool = false
    var commitActivityWindow: CommitActivityWindow = .sevenDays

    private enum CodingKeys: String, CodingKey {
        case refreshInterval
        case hideDockIcon
        case notifyOnStarIncrease
        case playSoundOnStarIncrease
        case starSoundThreshold
        case animateOnStarIncrease
        case celebrationMode
        case isMuted
        case gitHubOAuthClientID
        case menuBarDisplayMode
        case selectedMenuBarRepoID
        case repoTrendRange
        case maintainerRadarActivityWindow
        case hasPrivateRepoToken
        case commitActivityWindow
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshInterval = try container.decode(RefreshInterval.self, forKey: .refreshInterval)
        hideDockIcon = try container.decode(Bool.self, forKey: .hideDockIcon)
        notifyOnStarIncrease = try container.decode(Bool.self, forKey: .notifyOnStarIncrease)
        playSoundOnStarIncrease = try container.decode(Bool.self, forKey: .playSoundOnStarIncrease)
        starSoundThreshold = try container.decodeIfPresent(StarSoundThreshold.self, forKey: .starSoundThreshold) ?? .one
        animateOnStarIncrease = try container.decode(Bool.self, forKey: .animateOnStarIncrease)
        celebrationMode = try container.decodeIfPresent(CelebrationMode.self, forKey: .celebrationMode)
            ?? (animateOnStarIncrease ? .subtle : .off)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        gitHubOAuthClientID = try container.decode(String.self, forKey: .gitHubOAuthClientID)
        menuBarDisplayMode = try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .selectedRepoStars
        selectedMenuBarRepoID = try container.decodeIfPresent(UUID.self, forKey: .selectedMenuBarRepoID)
        repoTrendRange = try container.decodeIfPresent(RepoTrendRange.self, forKey: .repoTrendRange) ?? .all
        maintainerRadarActivityWindow = try container.decodeIfPresent(MaintainerRadarActivityWindow.self, forKey: .maintainerRadarActivityWindow) ?? .oneDay
        hasPrivateRepoToken = try container.decodeIfPresent(Bool.self, forKey: .hasPrivateRepoToken) ?? false
        commitActivityWindow = try container.decodeIfPresent(CommitActivityWindow.self, forKey: .commitActivityWindow) ?? .sevenDays
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    private let defaults: UserDefaults
    private let key = "GHMenuStars.AppSettings.v1"

    var settingsDidChange: AnyPublisher<AppSettings, Never> {
        $settings.eraseToAnyPublisher()
    }

    init(
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: "com.jazzyalex.GHMenuStars")
    ) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else if let data = legacyDefaults?.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
            defaults.set(data, forKey: key)
        } else {
            self.settings = AppSettings()
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
