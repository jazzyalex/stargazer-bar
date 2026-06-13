import AppKit

@MainActor
struct StatusMenuBuilder {
    let repoStore: TrackedRepoStore
    let settingsStore: SettingsStore
    let pollingService: RepoPollingService
    let updaterController: UpdaterController

    func build(target: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        if repoStore.trackedRepos.isEmpty {
            menu.addItem(titleItem("No repositories tracked", imageName: "star.slash"))
            menu.addItem(titleItem("Add up to \(TrackedRepoStore.maximumTrackedRepos) public repositories in Settings."))
        } else {
            for repo in repoStore.trackedRepos {
                menu.addItem(repoSelectionItem(repo, target: target))
            }
            if let state = repoStore.rateLimitState, state.isLimited {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(titleItem("Rate limit active", imageName: "exclamationmark.triangle"))
                menu.addItem(titleItem("Retry \(RelativeDateTimeFormatter.menu.string(for: state.resetAt) ?? "later")."))
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Check Now", #selector(StatusItemController.checkNow), target))
        let openItem = actionItem("Open Selected on GitHub", #selector(StatusItemController.openGitHub), target)
        openItem.isEnabled = repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID) != nil
        menu.addItem(openItem)
        let starItem = actionItem("Star on GitHub", #selector(StatusItemController.openProjectForStar), target)
        starItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        menu.addItem(starItem)
        menu.addItem(displayModeItem(target: target))
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
        let automaticUpdatesItem = actionItem(
            "Automatic Updates",
            #selector(StatusItemController.toggleAutomaticUpdates),
            target
        )
        automaticUpdatesItem.state = updaterController.autoUpdateEnabled ? .on : .off
        automaticUpdatesItem.isEnabled = updaterController.canChangeAutoUpdatePreference
        menu.addItem(automaticUpdatesItem)
        let updateTitle = updaterController.hasGentleReminder ? "Install Update…" : "Check for Updates…"
        let updateItem = actionItem(updateTitle, #selector(StatusItemController.checkForUpdates), target)
        updateItem.isEnabled = updaterController.canRequestUpdateCheck
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Quit", #selector(StatusItemController.quit), target))
        return menu
    }

    private func repoSelectionItem(_ repo: TrackedRepo, target: StatusItemController) -> NSMenuItem {
        let item = actionItem(
            repoLine(repo),
            #selector(StatusItemController.showRepoInMenuBar(_:)),
            target,
            representedObject: repo.id
        )
        item.attributedTitle = repoLineTitle(repo)
        item.state = isSelected(repo) ? .on : .off
        if isSelected(repo) {
            item.submenu = snapshotMenu(for: repo)
        }
        return item
    }

    private func displayModeItem(target: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in MenuBarDisplayMode.allCases {
            let modeItem = actionItem(
                mode.displayName,
                #selector(StatusItemController.setDisplayMode(_:)),
                target,
                representedObject: mode.rawValue
            )
            modeItem.state = settingsStore.settings.menuBarDisplayMode == mode ? .on : .off
            modeItem.isEnabled = !mode.requiresSelectedRepo || !repoStore.trackedRepos.isEmpty
            submenu.addItem(modeItem)
        }
        item.submenu = submenu
        return item
    }

    private func repoLine(_ repo: TrackedRepo) -> String {
        let stars = RepoDeltaFormatter.metricLine(label: "☆", value: repo.lastStars, delta: repo.lastStarsDelta)
        let downloads = RepoDeltaFormatter.metricLine(label: "↓", value: repo.lastDownloads, delta: repo.lastDownloadsDelta)
        return "\(repo.displayName)  \(stars)  \(downloads)"
    }

    private func repoLineTitle(_ repo: TrackedRepo) -> NSAttributedString {
        let regularFont = NSFont.menuFont(ofSize: 0)
        let boldFont = NSFont.boldSystemFont(ofSize: regularFont.pointSize)
        let title = repoLine(repo)
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [.font: regularFont]
        )
        var searchLocation = (repo.displayName as NSString).length
        for value in [repo.lastStars, repo.lastStarsDelta, repo.lastDownloads, repo.lastDownloadsDelta] {
            guard let value,
                  let formatted = NumberFormatter.menuInteger.string(from: NSNumber(value: value)) else { continue }
            let searchRange = NSRange(
                location: searchLocation,
                length: max(0, (title as NSString).length - searchLocation)
            )
            let range = (title as NSString).range(of: formatted, options: [], range: searchRange)
            if range.location != NSNotFound {
                attributed.addAttribute(.font, value: boldFont, range: range)
                searchLocation = range.location + range.length
            }
        }
        return attributed
    }

    private func isSelected(_ repo: TrackedRepo) -> Bool {
        repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID)?.id == repo.id
    }

    private func snapshotMenu(for repo: TrackedRepo) -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(titleItem(repo.displayName))
        submenu.addItem(metricItem(title: "Stars", value: repo.lastStars, delta: repo.lastStarsDelta, maxValue: snapshotMaxValue(for: repo)))
        submenu.addItem(metricItem(title: "Downloads", value: repo.lastDownloads, delta: repo.lastDownloadsDelta, maxValue: snapshotMaxValue(for: repo)))
        submenu.addItem(metricItem(title: "Forks", value: repo.lastForks, delta: repo.lastForksDelta, maxValue: snapshotMaxValue(for: repo)))
        return submenu
    }

    private func snapshotMaxValue(for repo: TrackedRepo) -> Int {
        max(repo.lastStars ?? 0, repo.lastDownloads ?? 0, repo.lastForks ?? 0, 1)
    }

    private func metricItem(title: String, value: Int?, delta: Int?, maxValue: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SnapshotMetricView(
            title: title,
            value: value,
            delta: delta,
            maxValue: maxValue
        )
        return item
    }

    private func titleItem(_ title: String, imageName: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let imageName {
            item.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        }
        item.isEnabled = false
        return item
    }

    private func actionItem(
        _ title: String,
        _ action: Selector,
        _ target: AnyObject,
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = representedObject
        return item
    }
}

private final class SnapshotMetricView: NSView {
    private let title: String
    private let value: Int?
    private let delta: Int?
    private let maxValue: Int

    init(title: String, value: Int?, delta: Int?, maxValue: Int) {
        self.title = title
        self.value = value
        self.delta = delta
        self.maxValue = max(1, maxValue)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 300, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        title.draw(
            in: NSRect(x: 12, y: 7, width: 74, height: 14),
            withAttributes: labelAttributes
        )

        let barFrame = NSRect(x: 88, y: 9, width: 92, height: 8)
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: barFrame, xRadius: 4, yRadius: 4).fill()

        if let value {
            let ratio = sqrt(CGFloat(value) / CGFloat(maxValue))
            let fillWidth = max(4, min(barFrame.width, barFrame.width * ratio))
            let fillFrame = NSRect(x: barFrame.minX, y: barFrame.minY, width: fillWidth, height: barFrame.height)
            NSColor.systemYellow.setFill()
            NSBezierPath(roundedRect: fillFrame, xRadius: 4, yRadius: 4).fill()
        }

        let valueText = formattedValue
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        valueText.draw(
            in: NSRect(x: 190, y: 7, width: 96, height: 14),
            withAttributes: valueAttributes
        )
    }

    private var formattedValue: String {
        let base: String
        if let value {
            base = NumberFormatter.menuInteger.string(from: NSNumber(value: value)) ?? "\(value)"
        } else {
            base = "--"
        }
        guard let delta, delta > 0 else { return base }
        let formattedDelta = NumberFormatter.menuInteger.string(from: NSNumber(value: delta)) ?? "\(delta)"
        return "\(base) +\(formattedDelta)"
    }
}
