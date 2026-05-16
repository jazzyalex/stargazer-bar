import AppKit

@MainActor
struct StatusMenuBuilder {
    let repoStore: TrackedRepoStore
    let settingsStore: SettingsStore
    let pollingService: RepoPollingService
    let updaterController: UpdaterController

    func build(target: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        if let repo = repoStore.trackedRepos.first {
            menu.addItem(titleItem(repo.displayName, imageName: "star.circle.fill"))
            let stars = RepoDeltaFormatter.metricLine(
                label: "★",
                value: repo.lastStars,
                delta: repoStore.lastDelta?.starsDelta
            )
            menu.addItem(titleItem(stars))
            let downloads = RepoDeltaFormatter.metricLine(
                label: "Release downloads:",
                value: repo.lastDownloads,
                delta: repoStore.lastDelta?.downloadsDelta
            )
            menu.addItem(titleItem(downloads))
            menu.addItem(titleItem("Checked \(RelativeDateTimeFormatter.menu.string(for: repo.lastCheckedAt) ?? "never")"))
            if let state = repoStore.rateLimitState, state.isLimited {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(titleItem("Rate limit active", imageName: "exclamationmark.triangle"))
                menu.addItem(titleItem("Retry \(RelativeDateTimeFormatter.menu.string(for: state.resetAt) ?? "later")."))
            }
        } else {
            menu.addItem(titleItem("No repository tracked", imageName: "star.slash"))
            menu.addItem(titleItem("Add a public repository in Settings."))
        }

        menu.addItem(NSMenuItem.separator())
        let openItem = actionItem("Open on GitHub", #selector(StatusItemController.openGitHub), target)
        openItem.isEnabled = repoStore.trackedRepos.first != nil
        menu.addItem(openItem)
        menu.addItem(actionItem("Check Now", #selector(StatusItemController.checkNow), target))
        menu.addItem(NSMenuItem.separator())
        let muteItem = actionItem(
            settingsStore.settings.isMuted ? "Mute: On" : "Mute: Off",
            #selector(StatusItemController.toggleMute),
            target
        )
        muteItem.state = settingsStore.settings.isMuted ? .on : .off
        menu.addItem(muteItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Settings…", #selector(StatusItemController.openSettings), target))
        let updateTitle = updaterController.hasGentleReminder ? "Install Update…" : "Check for Updates…"
        let updateItem = actionItem(updateTitle, #selector(StatusItemController.checkForUpdates), target)
        updateItem.isEnabled = updaterController.canCheckForUpdates
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Quit", #selector(StatusItemController.quit), target))
        return menu
    }

    private func titleItem(_ title: String, imageName: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let imageName {
            item.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        }
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
