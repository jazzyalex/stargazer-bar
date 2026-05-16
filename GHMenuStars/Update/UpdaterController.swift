import Cocoa
import Sparkle

@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published var hasGentleReminder = false
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?
    private var canCheckForUpdatesObservation: NSKeyValueObservation?
    private let defaultAutoUpdateEnabled: Bool

    override init() {
        self.defaultAutoUpdateEnabled = Self.hasConfiguredFeedURL &&
            ((Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool) ?? false)
        super.init()

        guard !AppDelegate.isHostedUnitTest() else { return }
        guard Self.hasConfiguredFeedURL else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        canCheckForUpdatesObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheckForUpdates = change.newValue ?? false
            Task { @MainActor in
                self?.canCheckForUpdates = canCheckForUpdates
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let controller = self?.controller else { return }
            do {
                try controller.updater.start()
            } catch {
                print("Failed to start updater - \(error.localizedDescription)")
            }
        }
    }

    var updater: SPUUpdater? {
        controller?.updater
    }

    var autoUpdateEnabled: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? defaultAutoUpdateEnabled }
        set {
            guard let updater = controller?.updater else { return }
            updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        hasGentleReminder = false
        controller?.checkForUpdates(sender)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            hasGentleReminder = !handleShowingUpdate
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            hasGentleReminder = false
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            hasGentleReminder = false
        }
    }

    nonisolated func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool {
        true
    }

    nonisolated func updaterDidFinishCheckingForUpdates(_ updater: SPUUpdater, error: Error?) {
        if let error {
            print("Update check failed - \(error.localizedDescription)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("Update available - \(item.displayVersionString)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        print("Already up to date")
    }

    private static var hasConfiguredFeedURL: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
