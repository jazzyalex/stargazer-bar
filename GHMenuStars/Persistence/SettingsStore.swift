import Combine
import Foundation

struct AppSettings: Codable, Equatable {
    var refreshInterval: RefreshInterval = .tenMinutes
    var hideDockIcon: Bool = true
    var notifyOnStarIncrease: Bool = true
    var playSoundOnStarIncrease: Bool = false
    var animateOnStarIncrease: Bool = true
    var gitHubOAuthClientID: String = ""
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    private let defaults: UserDefaults
    private let key = "GHMenuStars.AppSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
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

