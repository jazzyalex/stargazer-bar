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
