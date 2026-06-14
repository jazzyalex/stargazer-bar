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
        let updateTitle = updaterController.hasGentleReminder ? "Install Update…" : "Check for Updates…"
        let updateItem = actionItem(updateTitle, #selector(StatusItemController.checkForUpdates), target)
        updateItem.isEnabled = updaterController.canRequestUpdateCheck
        menu.addItem(updateItem)
        let starItem = actionItem("★ Star", #selector(StatusItemController.openProjectForStar), target)
        starItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        menu.addItem(starItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Quit", #selector(StatusItemController.quit), target))
        return menu
    }

    private func repoSelectionItem(_ repo: TrackedRepo, target: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: repoLine(repo), action: nil, keyEquivalent: "")
        item.attributedTitle = repoLineTitle(repo)
        item.state = isSelected(repo) ? .on : .off
        item.submenu = trendMenu(for: repo, target: target)
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

    private func trendMenu(for repo: TrackedRepo, target: StatusItemController) -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(titleItem(repo.displayName))
        submenu.addItem(trendItem(for: repo))
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(shareMenuItem(for: repo, target: target))
        return submenu
    }

    private func trendItem(for repo: TrackedRepo) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = RepoTrendView(repo: repo, trendRange: settingsStore.settings.repoTrendRange)
        return item
    }

    private func shareMenuItem(for repo: TrackedRepo, target: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: "Share Milestone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for (index, metric) in [MilestoneMetric.stars, .downloads].enumerated() {
            if index > 0 {
                submenu.addItem(NSMenuItem.separator())
            }

            let request = MilestoneShareRequest(repoID: repo.id, metric: metric)
            let isEnabled = RepoMilestoneShare.make(repo: repo, metric: metric) != nil
            let copyItem = actionItem(
                "Copy \(metric.displayName) Text",
                #selector(StatusItemController.copyMilestoneText(_:)),
                target,
                representedObject: request
            )
            copyItem.isEnabled = isEnabled
            submenu.addItem(copyItem)

            let imageItem = actionItem(
                "Copy \(metric.displayName) Image",
                #selector(StatusItemController.copyMilestoneImage(_:)),
                target,
                representedObject: request
            )
            imageItem.isEnabled = isEnabled
            submenu.addItem(imageItem)

            let xItem = actionItem(
                "Compose X \(metric.displayName) Post + Copy Image",
                #selector(StatusItemController.composeXPostWithMilestoneImage(_:)),
                target,
                representedObject: request
            )
            xItem.isEnabled = isEnabled
            submenu.addItem(xItem)
        }

        item.submenu = submenu
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

private final class RepoTrendView: NSView {
    private let repo: TrackedRepo
    private let trendRange: RepoTrendRange
    private let calendar = Calendar(identifier: .gregorian)

    init(repo: TrackedRepo, trendRange: RepoTrendRange) {
        self.repo = repo
        self.trendRange = trendRange
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 142))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 310, height: 142)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        trendRange.chartTitle.draw(in: NSRect(x: 12, y: 114, width: 116, height: 16), withAttributes: titleAttributes)

        drawLegend()
        let plot = NSRect(x: 44, y: 24, width: 252, height: 82)

        let points = trendPoints
        guard !points.isEmpty else {
            drawEmptyState(in: plot)
            return
        }

        let values = points.flatMap { [$0.stars, $0.forks] }
        let minValue = values.min() ?? 0
        let maxValue = max(values.max() ?? 1, minValue + 1)
        let start = chartStart(for: points)
        let end = Date()
        drawGrid(in: plot)
        drawHorizontalTicks(in: plot, start: start, end: end)
        drawScale(in: plot, minValue: minValue, maxValue: maxValue)
        drawLine(points: points, metric: \.stars, color: .systemYellow, plot: plot, minValue: minValue, maxValue: maxValue, start: start, end: end)
        drawLine(points: points, metric: \.forks, color: .systemBlue, plot: plot, minValue: minValue, maxValue: maxValue, start: start, end: end)
        drawRangeLabels(in: plot)
    }

    private var trendPoints: [RepoTrendPoint] {
        let now = Date()
        let stored = repo.trendPoints.sorted { $0.date < $1.date }
        let start = trendRange.startDate(now: now, calendar: calendar)
        let currentStars = repo.lastStars ?? stored.last?.stars ?? 0
        let currentForks = repo.lastForks ?? stored.last?.forks ?? 0

        if stored.isEmpty {
            return []
        }

        guard let start else {
            if let last = stored.last, !calendar.isDate(last.date, inSameDayAs: now) {
                return stored + [RepoTrendPoint(date: now, stars: currentStars, forks: currentForks)]
            }
            return stored
        }

        var scoped = stored.filter { $0.date >= start }
        if let previous = stored.last(where: { $0.date < start }) {
            scoped.insert(RepoTrendPoint(date: start, stars: previous.stars, forks: previous.forks), at: 0)
        } else if scoped.first?.date != start {
            scoped.insert(RepoTrendPoint(date: start, stars: scoped.first?.stars ?? currentStars, forks: scoped.first?.forks ?? currentForks), at: 0)
        }

        if scoped.count == 1 {
            return [
                RepoTrendPoint(date: start, stars: scoped[0].stars, forks: scoped[0].forks),
                RepoTrendPoint(date: now, stars: currentStars, forks: currentForks)
            ]
        }

        if let last = scoped.last, !calendar.isDate(last.date, inSameDayAs: now) {
            return scoped + [RepoTrendPoint(date: now, stars: currentStars, forks: currentForks)]
        }
        return scoped
    }

    private func chartStart(for points: [RepoTrendPoint]) -> Date {
        let now = Date()
        if let start = trendRange.startDate(now: now, calendar: calendar) {
            return start
        }
        return points.first?.date ?? now
    }

    private func xPosition(for date: Date, in plot: NSRect, start: Date, end: Date) -> CGFloat {
        let span = max(1, end.timeIntervalSince(start))
        let progress = min(1, max(0, date.timeIntervalSince(start) / span))
        return plot.minX + plot.width * CGFloat(progress)
    }

    private func yPosition(for value: Int, in plot: NSRect, minValue: Int, maxValue: Int) -> CGFloat {
        let span = max(1, maxValue - minValue)
        let progress = CGFloat(value - minValue) / CGFloat(span)
        return plot.minY + plot.height * progress
    }

    private func drawLine(
        points: [RepoTrendPoint],
        metric: KeyPath<RepoTrendPoint, Int>,
        color: NSColor,
        plot: NSRect,
        minValue: Int,
        maxValue: Int,
        start: Date,
        end: Date
    ) {
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let position = NSPoint(
                x: xPosition(for: point.date, in: plot, start: start, end: end),
                y: yPosition(for: point[keyPath: metric], in: plot, minValue: minValue, maxValue: maxValue)
            )
            index == 0 ? path.move(to: position) : path.line(to: position)
        }
        path.lineWidth = 1.8
        color.setStroke()
        path.stroke()
    }

    private func drawGrid(in plot: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        let frame = NSBezierPath(roundedRect: plot, xRadius: 5, yRadius: 5)
        frame.lineWidth = 1
        frame.stroke()

        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        for step in 1...2 {
            let y = plot.minY + plot.height * CGFloat(step) / 3
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.6
            line.stroke()
        }
    }

    private func drawHorizontalTicks(in plot: NSRect, start: Date, end: Date) {
        let ticks = RepoTrendAxisTickBuilder.ticks(start: start, end: end, calendar: calendar, maxTicks: 5)
        let lineColor = NSColor.separatorColor.withAlphaComponent(0.28)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        for tick in ticks {
            let x = xPosition(for: tick.date, in: plot, start: start, end: end)
            lineColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plot.minY))
            line.line(to: NSPoint(x: x, y: plot.maxY))
            line.lineWidth = 0.5
            line.stroke()

            tick.label.draw(
                in: NSRect(x: x - 16, y: plot.minY - 15, width: 32, height: 10),
                withAttributes: attributes
            )
        }
    }

    private func drawScale(in plot: NSRect, minValue: Int, maxValue: Int) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let middle = (minValue + maxValue) / 2
        let ticks: [(Int, CGFloat)] = [
            (maxValue, plot.maxY - 6),
            (middle, plot.midY - 5),
            (minValue, plot.minY - 5)
        ]
        for (value, y) in ticks {
            let text = NumberFormatter.menuInteger.string(from: NSNumber(value: value)) ?? "\(value)"
            text.draw(in: NSRect(x: 6, y: y, width: 34, height: 11), withAttributes: attributes)
        }
    }

    private func drawLegend() {
        drawLegendItem("Stars", color: .systemYellow, x: 172)
        drawLegendItem("Forks", color: .systemBlue, x: 232)
    }

    private func drawLegendItem(_ title: String, color: NSColor, x: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 119, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
        title.draw(
            in: NSRect(x: x + 12, y: 115, width: 42, height: 14),
            withAttributes: [
                .font: NSFont.menuFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }

    private func drawRangeLabels(in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        trendRange.axisLabel.draw(in: NSRect(x: plot.minX - 2, y: plot.minY - 23, width: 32, height: 11), withAttributes: attributes)
        "now".draw(in: NSRect(x: plot.maxX - 26, y: plot.minY - 15, width: 28, height: 11), withAttributes: attributes)
    }

    private func drawEmptyState(in plot: NSRect) {
        "Loading GitHub history…".draw(
            in: NSRect(x: plot.minX + 64, y: plot.midY - 8, width: 170, height: 16),
            withAttributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }
}
