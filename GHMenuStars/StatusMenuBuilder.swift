import AppKit

@MainActor
struct StatusMenuBuilder {
    let repoStore: TrackedRepoStore
    let settingsStore: SettingsStore
    let pollingService: RepoPollingService

    func build(target: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        if let repo = repoStore.trackedRepos.first {
            menu.addItem(titleItem(repo.displayName))
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
                menu.addItem(titleItem("GitHub rate limit active. Next retry \(RelativeDateTimeFormatter.menu.string(for: state.resetAt) ?? "later")."))
            }
        } else {
            menu.addItem(titleItem("No repository tracked"))
            menu.addItem(titleItem("Add a public GitHub repository in Settings."))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Check Now", #selector(StatusItemController.checkNow), target))
        let openItem = actionItem("Open on GitHub", #selector(StatusItemController.openGitHub), target)
        openItem.isEnabled = repoStore.trackedRepos.first != nil
        menu.addItem(openItem)
        menu.addItem(actionItem("Settings…", #selector(StatusItemController.openSettings), target))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Quit", #selector(StatusItemController.quit), target))
        return menu
    }

    private func titleItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}

