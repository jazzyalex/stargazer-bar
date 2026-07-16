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
            menu.addItem(titleItem("Add up to \(TrackedRepoStore.maximumTrackedRepos) repositories in Settings."))
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
        if let shareItem = selectedShareMenuItem(target: target) {
            menu.addItem(shareItem)
        }
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

    /// Private repos drop the star segment: their stars are never fetched, so a
    /// glyph here would render a number nobody looked up.
    static func repoLineText(_ repo: TrackedRepo) -> String {
        let downloads = RepoDeltaFormatter.metricLine(label: "⤓", value: repo.lastDownloads, delta: repo.lastDownloadsDelta)
        // A private WIP repo usually has no releases, so a downloads figure is a
        // zero that measures nothing. What it does have is commits and things
        // needing attention — show those, and only mention downloads if any exist.
        guard !repo.isPrivate else {
            var parts: [String] = [repo.displayName]
            if let commits = repo.maintainerRadar?.recentCommits, commits > 0 {
                parts.append("⎇ \(Self.formattedCount(commits))")
            }
            if let attention = repo.maintainerRadar?.attentionCount, attention > 0 {
                parts.append("◈ \(Self.formattedCount(attention))")
            }
            if let dl = repo.lastDownloads, dl > 0 {
                parts.append(downloads)
            }
            if parts.count == 1 { parts.append("—") }
            return parts.joined(separator: "  ")
        }
        let stars = RepoDeltaFormatter.metricLine(label: "☆", value: repo.lastStars, delta: repo.lastStarsDelta)
        return "\(repo.displayName)  \(stars)  \(downloads)"
    }

    private func repoLine(_ repo: TrackedRepo) -> String {
        Self.repoLineText(repo)
    }

    private func repoLineTitle(_ repo: TrackedRepo) -> NSAttributedString {
        let regularFont = NSFont.menuFont(ofSize: 0)
        let boldFont = NSFont.boldSystemFont(ofSize: regularFont.pointSize)
        let title = repoLine(repo)
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [.font: regularFont]
        )
        // Bold only the numbers metricLine actually renders. A delta is shown
        // solely when > 0 (see RepoDeltaFormatter.metricLine); feeding a 0 delta
        // here makes range(of: "0") match a digit inside a later metric (e.g. the
        // 0 in "101") and mis-bold a single character.
        var displayedNumbers: [Int] = []
        if let stars = repo.lastStars { displayedNumbers.append(stars) }
        if let starsDelta = repo.lastStarsDelta, starsDelta > 0 { displayedNumbers.append(starsDelta) }
        if let downloads = repo.lastDownloads { displayedNumbers.append(downloads) }
        if let downloadsDelta = repo.lastDownloadsDelta, downloadsDelta > 0 { displayedNumbers.append(downloadsDelta) }

        var searchLocation = (repo.displayName as NSString).length
        for value in displayedNumbers {
            guard let formatted = NumberFormatter.menuInteger.string(from: NSNumber(value: value)) else { continue }
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
        // Off, so a no-action item isn't auto-disabled and greyed. Grey items
        // opt in via isEnabled = false (titleItem); the black header stays
        // enabled. Nothing here uses validateMenuItem, so this changes only
        // appearance, and actionable rows keep working via their target/action.
        submenu.autoenablesItems = false
        submenu.addItem(titleItem(repo.displayName))
        if repo.isPrivate {
            // A private repo has no star history to chart, but it does have
            // commits — which is the thing being watched. Removing the chart
            // entirely (as this did) threw away the surface because the old
            // data didn't fit, instead of putting the right data in it.
            if let buckets = repo.commitActivity, !buckets.isEmpty {
                let item = NSMenuItem()
                item.view = RepoCommitActivityView(repo: repo, buckets: buckets)
                submenu.addItem(item)
            }
        } else {
            submenu.addItem(trendItem(for: repo))
        }
        addLatestReleaseItems(to: submenu, for: repo)
        addRecentReleasesItems(to: submenu, for: repo)
        if !repo.isPrivate {
            // Highlights sits after the release sections now: releases are the
            // headline, Best day / Peak week are the footnote.
            addTrendHighlightItems(to: submenu, for: repo)
        }
        submenu.addItem(NSMenuItem.separator())
        addMaintainerRadarItems(to: submenu, for: repo, target: target)
        submenu.addItem(NSMenuItem.separator())
        // The share factory refuses private repos, so building this for one
        // yields a submenu whose every action is dead. Omit it instead.
        if !repo.isPrivate {
            submenu.addItem(shareMenuItem(title: "Share Milestone", for: repo, target: target))
        }
        submenu.addItem(openRepoItem(repo, target: target))
        return submenu
    }

    private func trendItem(for repo: TrackedRepo) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = RepoTrendView(
            repo: repo,
            trendRange: settingsStore.settings.repoTrendRange,
            releaseDate: repo.latestRelease?.publishedAt,
            anomalies: TrendAnomalyDetector.anomalies(in: repo.trendPoints)
        )
        return item
    }

    /// Two derived "standout moment" rows under the chart — the biggest single
    /// star day and the hottest 7-day stretch — computed from stored trend
    /// history. Omitted entirely when history is too short to be meaningful.
    private func addTrendHighlightItems(to submenu: NSMenu, for repo: TrackedRepo) {
        let best = TrendAnomalyStats.bestDay(in: repo.trendPoints)
        let peak = TrendAnomalyStats.peakWeek(in: repo.trendPoints)
        guard best != nil || peak != nil else { return }

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(headerItem("Highlights"))
        if let best {
            submenu.addItem(titleItem(
                "Best day: +\(Self.formattedCount(best.gain)) ⭐ · \(Self.dayLabel(best.date))",
                imageName: "star.circle"
            ))
        }
        if let peak {
            submenu.addItem(titleItem(
                "Peak week: +\(Self.formattedCount(peak.gain)) ⭐ · \(Self.weekLabel(peak))",
                imageName: "calendar"
            ))
        }
    }

    private func selectedShareMenuItem(target: StatusItemController) -> NSMenuItem? {
        guard let repo = repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID),
              canShareMilestone(for: repo) else {
            return nil
        }
        return shareMenuItem(title: "Share Selected Milestone", for: repo, target: target)
    }

    private func shareMenuItem(title: String, for repo: TrackedRepo, target: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let request = MilestoneShareRequest(repoID: repo.id, metric: .stars)
        let share = RepoMilestoneShare.make(repo: repo, metric: .stars)
        let isEnabled = share != nil
        let badge = share.map { " (\($0.formattedMilestoneValue)+ stars)" } ?? ""

        let copyText = actionItem(
            "Copy Text\(badge)",
            #selector(StatusItemController.copyMilestoneText(_:)),
            target,
            representedObject: request
        )
        copyText.isEnabled = isEnabled
        submenu.addItem(copyText)

        let imageItem = actionItem(
            "Copy Image\(badge)",
            #selector(StatusItemController.copyMilestoneImage(_:)),
            target,
            representedObject: request
        )
        imageItem.isEnabled = isEnabled
        submenu.addItem(imageItem)

        let xItem = actionItem(
            "Compose X Post + Copy Image\(badge)",
            #selector(StatusItemController.composeXPostWithMilestoneImage(_:)),
            target,
            representedObject: request
        )
        xItem.isEnabled = isEnabled
        submenu.addItem(xItem)

        item.submenu = submenu
        return item
    }

    private func canShareMilestone(for repo: TrackedRepo) -> Bool {
        RepoMilestoneShare.make(repo: repo, metric: .stars) != nil
    }

    private func addLatestReleaseItems(to submenu: NSMenu, for repo: TrackedRepo) {
        guard let release = repo.latestRelease else { return }
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(headerItem("Latest release"))
        let age = RelativeDateTimeFormatter.menu.string(for: release.publishedAt) ?? "recently"
        let tagLine = "\(release.tag) · \(age)" + (release.isPrerelease ? " · pre" : "")
        submenu.addItem(titleItem(tagLine, imageName: "tag"))
        submenu.addItem(titleItem(ReleaseLineFormatter.adoptionLine(release), imageName: "arrow.down.circle"))
    }

    private func addRecentReleasesItems(to submenu: NSMenu, for repo: TrackedRepo) {
        guard let summary = repo.recentReleases else { return }
        let rows = RecentReleasesLineFormatter.rows(
            summary,
            trendPoints: repo.trendPoints,
            currentStars: repo.lastStars ?? 0,
            currentForks: repo.lastForks ?? 0
        )
        guard !rows.isEmpty else { return }
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(headerItem("Last 30 days"))
        for row in rows {
            submenu.addItem(titleItem(row.text, imageName: row.image))
        }
    }

    private func addMaintainerRadarItems(to submenu: NSMenu, for repo: TrackedRepo, target: StatusItemController) {
        guard let radar = repo.maintainerRadar, radar.hasData else {
            submenu.addItem(titleItem("Check Now to load radar", imageName: "arrow.clockwise"))
            submenu.addItem(discussionsItem(for: repo, target: target))
            return
        }

        let ciFailing = radar.latestFailedWorkflow
        if let workflow = ciFailing {
            // Date it. Without this a run that failed months ago and never ran
            // again reads identically to one that broke minutes ago — and on a
            // private repo, where the radar is the whole display, that stale
            // verdict is the loudest thing on screen.
            let when = workflow.failedAt.map { RelativeDateTimeFormatter.menu.string(for: $0) ?? "" } ?? ""
            let suffix = when.isEmpty ? "" : " (\(when))"
            submenu.addItem(urlItem(
                "CI failing: \(workflow.name)\(suffix)",
                imageName: "xmark.circle.fill",
                url: URL(string: workflow.url) ?? gitHubURL(for: repo, path: "/actions"),
                target: target
            ))
        }

        // One packed activity line, labelled by the release when anchored.
        let window = settingsStore.settings.maintainerRadarActivityWindow
        let anchorSince = radar.activityAnchoredSince
        let label: String
        if anchorSince != nil, let tag = repo.latestRelease?.tag {
            label = "Since \(tag)"
        } else {
            let menuLabel = window.menuLabel
            label = menuLabel.isEmpty ? "Recent" : menuLabel.prefix(1).uppercased() + menuLabel.dropFirst()
        }
        var activityParts: [String] = []
        if let commits = radar.recentCommits, commits > 0 {
            activityParts.append("\(Self.formattedCount(commits)) \(commits == 1 ? "commit" : "commits")")
        }
        if let prs = radar.newPullRequests, prs > 0 {
            activityParts.append("\(Self.formattedCount(prs)) new \(prs == 1 ? "PR" : "PRs")")
        }
        if let issues = radar.newIssues, issues > 0 {
            activityParts.append("\(Self.formattedCount(issues)) new \(issues == 1 ? "issue" : "issues")")
        }
        if !repo.isPrivate,
           let release = repo.latestRelease,
           let stars = ReleaseDynamics.starsSinceRelease(trendPoints: repo.trendPoints, currentStars: repo.lastStars ?? 0, publishedAt: release.publishedAt),
           stars > 0 {
            activityParts.append("+\(Self.formattedCount(stars)) ⭐")
        }
        if !activityParts.isEmpty {
            submenu.addItem(headerItem(label))
            submenu.addItem(urlItem(
                activityParts.joined(separator: " · "),
                imageName: "chart.line.uptrend.xyaxis",
                url: gitHubURL(for: repo, path: "/commits"),
                target: target
            ))
        }

        // Open-state row: only the metrics that need attention.
        var openParts: [String] = []
        if let openPRs = radar.openPullRequests, openPRs > 0 {
            openParts.append("\(Self.formattedCount(openPRs)) open \(openPRs == 1 ? "PR" : "PRs")")
        }
        if let unanswered = radar.unansweredIssues, unanswered > 0 {
            openParts.append("\(Self.formattedCount(unanswered)) need first reply")
        }
        if !openParts.isEmpty {
            submenu.addItem(urlItem(
                openParts.joined(separator: " · "),
                imageName: "tray",
                url: gitHubURL(for: repo, path: "/issues", query: "is:issue is:open comments:0"),
                target: target
            ))
        }

        // Muted footer assembled from whichever healthy segments hold.
        var footerParts: [String] = []
        if ciFailing == nil, radar.workflowChecked { footerParts.append("CI clear") }
        if openParts.isEmpty { footerParts.append("nothing open") }
        footerParts.append("updated \(RelativeDateTimeFormatter.menu.string(for: radar.checkedAt) ?? "recently")")
        submenu.addItem(titleItem(footerParts.joined(separator: " · ")))
        submenu.addItem(discussionsItem(for: repo, target: target))
    }

    private func discussionsItem(for repo: TrackedRepo, target: StatusItemController) -> NSMenuItem {
        urlItem(
            "Open Discussions",
            imageName: "bubble.left.and.bubble.right",
            url: gitHubURL(for: repo, path: "/discussions"),
            target: target
        )
    }

    private func openRepoItem(_ repo: TrackedRepo, target: StatusItemController) -> NSMenuItem {
        urlItem(
            "Open on GitHub",
            imageName: "safari",
            url: gitHubURL(for: repo),
            target: target
        )
    }

    private func urlItem(
        _ title: String,
        imageName: String,
        url: URL?,
        target: StatusItemController,
        enabled: Bool = true,
        emphasizedText: String? = nil
    ) -> NSMenuItem {
        let item = actionItem(
            title,
            #selector(StatusItemController.openRepresentedURL(_:)),
            target,
            representedObject: url
        )
        if let emphasizedText {
            item.attributedTitle = Self.attributedMenuTitle(title, emphasizedText: emphasizedText)
        }
        item.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        item.isEnabled = enabled && url != nil
        return item
    }

    private func gitHubURL(for repo: TrackedRepo, path: String = "", query: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repo.owner)/\(repo.name)\(path)"
        if let query {
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url
    }

    private static func formattedCount(_ count: Int) -> String {
        NumberFormatter.menuInteger.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let dayOfMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    private static func dayLabel(_ date: Date) -> String {
        monthDayFormatter.string(from: date)
    }

    private static func weekLabel(_ peak: TrendAnomalyStats.PeakWeek) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let startText = monthDayFormatter.string(from: peak.start)
        if calendar.isDate(peak.start, equalTo: peak.end, toGranularity: .month) {
            return "\(startText)–\(dayOfMonthFormatter.string(from: peak.end))"
        }
        return "\(startText) – \(monthDayFormatter.string(from: peak.end))"
    }

    private static func attributedMenuTitle(_ title: String, emphasizedText: String) -> NSAttributedString {
        let regularFont = NSFont.menuFont(ofSize: 0)
        let boldFont = NSFont.boldSystemFont(ofSize: regularFont.pointSize)
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [.font: regularFont]
        )
        let range = (title as NSString).range(of: emphasizedText)
        if range.location != NSNotFound {
            attributed.addAttribute(.font, value: boldFont, range: range)
        }
        return attributed
    }

    /// A section header in solid label colour. A plain disabled item renders
    /// grey; an attributedTitle with an explicit colour overrides that dimming,
    /// so the header reads as a header rather than more secondary text.
    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // Enabled (so it isn't dimmed) but actionless, so it reads as a heading
        // in full label colour rather than the grey of the surrounding rows.
        // Relies on the submenu's autoenablesItems = false.
        item.isEnabled = true
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

/// Daily commits as bars.
///
/// A count answers "how much"; only a shape answers "is this moving or stalled",
/// which is the question a private WIP repo is actually being watched for. Bars
/// rather than a line: daily commit counts are discrete events, and a line
/// implies continuity between days that doesn't exist.
private final class RepoCommitActivityView: NSView {
    private let repo: TrackedRepo
    private let buckets: [CommitDayCount]
    private let calendar = Calendar(identifier: .gregorian)

    init(repo: TrackedRepo, buckets: [CommitDayCount]) {
        self.repo = repo
        self.buckets = buckets
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 96))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 310, height: 96) }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let title = "Commits · last 30 days"
        title.draw(at: NSPoint(x: 14, y: bounds.height - 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])

        let total = buckets.reduce(0) { $0 + $1.count }
        let totalText = "\(total)"
        let totalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let totalSize = totalText.size(withAttributes: totalAttrs)
        totalText.draw(at: NSPoint(x: bounds.width - 14 - totalSize.width, y: bounds.height - 18), withAttributes: totalAttrs)

        guard !buckets.isEmpty else { return }

        let plot = NSRect(x: 14, y: 22, width: bounds.width - 28, height: bounds.height - 48)
        let maxCount = max(buckets.map(\.count).max() ?? 0, 1)
        let slot = plot.width / CGFloat(buckets.count)
        let barWidth = max(2, slot * 0.7)

        for (index, bucket) in buckets.enumerated() {
            // Zero days still get a baseline tick: a gap would read as "no data"
            // rather than "no work", and those are different facts.
            let height = bucket.count == 0 ? 1 : max(2, plot.height * CGFloat(bucket.count) / CGFloat(maxCount))
            let x = plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2
            let rect = NSRect(x: x, y: plot.minY, width: barWidth, height: height)
            (bucket.count == 0 ? NSColor.quaternaryLabelColor : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }

        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        if let first = buckets.first?.date, let last = buckets.last?.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            formatter.string(from: first).draw(at: NSPoint(x: plot.minX, y: 6), withAttributes: axisAttrs)
            let lastText = formatter.string(from: last)
            let lastSize = lastText.size(withAttributes: axisAttrs)
            lastText.draw(at: NSPoint(x: plot.maxX - lastSize.width, y: 6), withAttributes: axisAttrs)
        }
    }
}

private final class RepoTrendView: NSView {
    private let repo: TrackedRepo
    private let trendRange: RepoTrendRange
    private let releaseDate: Date?
    private let anomalies: [AnomalyDay]
    private let calendar = Calendar(identifier: .gregorian)

    init(repo: TrackedRepo, trendRange: RepoTrendRange, releaseDate: Date? = nil, anomalies: [AnomalyDay] = []) {
        self.repo = repo
        self.trendRange = trendRange
        self.releaseDate = releaseDate
        self.anomalies = anomalies
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 142))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 310, height: 142)
    }

    override var isOpaque: Bool {
        false
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
        drawAnomalyMarkers(points: points, in: plot, start: start, end: end, minValue: minValue, maxValue: maxValue)
        drawLine(points: points, metric: \.forks, color: .systemBlue, plot: plot, minValue: minValue, maxValue: maxValue, start: start, end: end)
        drawReleaseMarker(in: plot, start: start, end: end)
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
            .foregroundColor: NSColor.secondaryLabelColor
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
            .foregroundColor: NSColor.secondaryLabelColor
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

    private func drawReleaseMarker(in plot: NSRect, start: Date, end: Date) {
        guard let releaseDate, releaseDate >= start, releaseDate <= end else { return }
        let x = xPosition(for: releaseDate, in: plot, start: start, end: end)

        NSColor.tertiaryLabelColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: plot.minY))
        line.line(to: NSPoint(x: x, y: plot.maxY))
        line.lineWidth = 1
        let dashPattern: [CGFloat] = [2, 2]
        line.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        line.stroke()

        NSColor.secondaryLabelColor.setFill()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: x - 4, y: plot.maxY + 6))
        marker.line(to: NSPoint(x: x + 4, y: plot.maxY + 6))
        marker.line(to: NSPoint(x: x, y: plot.maxY + 1))
        marker.close()
        marker.fill()
    }

    /// Pips on the star line marking days of abnormally high star growth. The
    /// cumulative value is read from the same points the line is drawn through, so
    /// each pip sits exactly on the line; a dark thin ring lifts it off the yellow.
    private func drawAnomalyMarkers(points: [RepoTrendPoint], in plot: NSRect, start: Date, end: Date, minValue: Int, maxValue: Int) {
        guard !anomalies.isEmpty else { return }
        for anomaly in anomalies {
            guard anomaly.date >= start, anomaly.date <= end else { continue }
            guard let match = points.first(where: { calendar.isDate($0.date, inSameDayAs: anomaly.date) }) else { continue }
            let center = NSPoint(
                x: xPosition(for: anomaly.date, in: plot, start: start, end: end),
                y: yPosition(for: match.stars, in: plot, minValue: minValue, maxValue: maxValue)
            )
            let radius: CGFloat = 3
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            NSColor.systemYellow.setFill()
            dot.fill()
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            dot.lineWidth = 0.75
            dot.stroke()
        }
    }

    private func drawRangeLabels(in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
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
