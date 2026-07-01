import AppKit
import Foundation

extension NumberFormatter {
    static let menuInteger: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

extension RelativeDateTimeFormatter {
    static let menu: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

enum RepoDeltaFormatter {
    static func metricLine(label: String, value: Int?, delta: Int?) -> String {
        let formattedValue: String
        if let value {
            formattedValue = NumberFormatter.menuInteger.string(from: NSNumber(value: value)) ?? "\(value)"
        } else {
            formattedValue = "--"
        }
        guard let delta, delta > 0 else { return "\(label) \(formattedValue)" }
        return "\(label) \(formattedValue)  +\(NumberFormatter.menuInteger.string(from: NSNumber(value: delta)) ?? "\(delta)")"
    }
}

enum ReleaseLineFormatter {
    static func adoptionLine(_ summary: LatestReleaseSummary, now: Date = Date()) -> String {
        let downloads = NumberFormatter.menuInteger.string(from: NSNumber(value: summary.downloads)) ?? "\(summary.downloads)"
        let rate = ReleaseDynamics.dailyRate(downloads: summary.downloads, publishedAt: summary.publishedAt, now: now)
        let rateText = NumberFormatter.menuInteger.string(from: NSNumber(value: rate)) ?? "\(rate)"
        var line = "\(downloads) ⤓ · ~\(rateText)/day"
        if let share = ReleaseDynamics.sharePercent(downloads: summary.downloads, totalDownloads: summary.totalDownloads) {
            line += " · \(share)% of all"
        }
        return line
    }

    static func assetLine(_ summary: LatestReleaseSummary) -> String? {
        guard summary.assets.count > 1 else { return nil }
        return summary.assets
            .map { "\($0.label) \(NumberFormatter.menuInteger.string(from: NSNumber(value: $0.count)) ?? "\($0.count)")" }
            .joined(separator: " · ")
    }
}

enum RecentReleasesLineFormatter {
    static func rows(_ summary: RecentReleasesSummary, trendPoints: [RepoTrendPoint], currentStars: Int, currentForks: Int, now: Date = Date()) -> [(image: String, text: String)] {
        let day = 24.0 * 60 * 60
        let windowStart = now.addingTimeInterval(-Double(ReleaseDynamics.recentWindowDays) * day)
        let priorStart = now.addingTimeInterval(-Double(ReleaseDynamics.recentWindowDays * 2) * day)
        let starsBase = ReleaseDynamics.value(in: trendPoints, at: windowStart, keyPath: \.stars)
        let forksBase = ReleaseDynamics.value(in: trendPoints, at: windowStart, keyPath: \.forks)
        let starsGained = starsBase.map { max(0, currentStars - $0) }
        let forksGained = forksBase.map { max(0, currentForks - $0) }

        var rows: [(image: String, text: String)] = []

        var line1: [String] = []
        if summary.releaseCount > 0 {
            line1.append("\(fmt(summary.releaseCount)) \(summary.releaseCount == 1 ? "release" : "releases")")
        }
        if let stars = starsGained, stars > 0 { line1.append("+\(fmt(stars)) ⭐") }
        if let forks = forksGained, forks > 0 { line1.append("+\(fmt(forks)) \(forks == 1 ? "fork" : "forks")") }
        if !line1.isEmpty { rows.append((image: "shippingbox", text: line1.joined(separator: " · "))) }

        if summary.downloads > 0 {
            var line2 = "\(fmt(summary.downloads)) ⤓ · ~\(fmt(rate(summary.downloads)))/day"
            if let share = ReleaseDynamics.sharePercent(downloads: summary.downloads, totalDownloads: summary.totalDownloads) {
                line2 += " · \(share)% of all"
            }
            rows.append((image: "arrow.down.circle", text: line2))
        }

        if let starsBase, let starsGained,
           let starsPrior = ReleaseDynamics.value(in: trendPoints, at: priorStart, keyPath: \.stars) {
            let priorStars = max(0, starsBase - starsPrior)
            if priorStars > 0 {
                let arrow = starsGained > priorStars ? "↑" : (starsGained < priorStars ? "↓" : "→")
                var line3 = ["\(arrow) vs prior \(ReleaseDynamics.recentWindowDays)d", "+\(fmt(priorStars)) ⭐"]
                if let forksBase, let forksPrior = ReleaseDynamics.value(in: trendPoints, at: priorStart, keyPath: \.forks) {
                    let priorForks = max(0, forksBase - forksPrior)
                    if priorForks > 0 { line3.append("+\(fmt(priorForks)) \(priorForks == 1 ? "fork" : "forks")") }
                }
                rows.append((image: "chart.line.uptrend.xyaxis", text: line3.joined(separator: " · ")))
            }
        }

        if summary.releaseCount > 0 {
            let days = max(1, Int((Double(ReleaseDynamics.recentWindowDays) / Double(summary.releaseCount)).rounded()))
            var line4 = summary.releaseCount == 1
                ? "1 release in \(ReleaseDynamics.recentWindowDays) days"
                : "~1 release / \(days) days"
            if summary.downloads > 0 {
                let avg = Int((Double(summary.downloads) / Double(summary.releaseCount)).rounded())
                line4 += " · avg \(fmt(avg)) ⤓/release"
            }
            rows.append((image: "clock", text: line4))
        }

        return rows
    }

    private static func fmt(_ value: Int) -> String {
        NumberFormatter.menuInteger.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func rate(_ downloads: Int) -> Int {
        Int((Double(downloads) / Double(ReleaseDynamics.recentWindowDays)).rounded())
    }
}

enum MilestoneMetric: String, Codable, Equatable {
    case stars
    case downloads

    var singularName: String {
        switch self {
        case .stars: return "star"
        case .downloads: return "download"
        }
    }

    var pluralName: String {
        switch self {
        case .stars: return "stars"
        case .downloads: return "downloads"
        }
    }

    var displayName: String {
        switch self {
        case .stars: return "Stars"
        case .downloads: return "Downloads"
        }
    }

    var symbolName: String {
        switch self {
        case .stars: return "star.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }
}

struct RepoMilestoneShare: Equatable {
    var repoDisplayName: String
    var metric: MilestoneMetric
    var currentValue: Int
    var milestoneValue: Int

    var formattedCurrentValue: String {
        NumberFormatter.menuInteger.string(from: NSNumber(value: currentValue)) ?? "\(currentValue)"
    }

    var formattedMilestoneValue: String {
        NumberFormatter.menuInteger.string(from: NSNumber(value: milestoneValue)) ?? "\(milestoneValue)"
    }

    var isRounded: Bool {
        milestoneValue != currentValue
    }

    static func make(repo: TrackedRepo, metric: MilestoneMetric) -> RepoMilestoneShare? {
        let currentValue: Int?
        switch metric {
        case .stars:
            currentValue = repo.lastStars
        case .downloads:
            currentValue = repo.lastDownloads
        }

        guard let currentValue, currentValue > 0 else { return nil }
        return RepoMilestoneShare(
            repoDisplayName: repo.displayName,
            metric: metric,
            currentValue: currentValue,
            milestoneValue: MilestoneRounding.displayValue(for: currentValue)
        )
    }
}

enum MilestoneRounding {
    static let presetValues: [Int] = [
        10, 50,
        100, 200, 300, 400, 500, 600, 700, 800, 900,
        1_000, 5_000, 10_000, 20_000, 30_000, 40_000, 50_000
    ]

    static func displayValue(for currentValue: Int) -> Int {
        guard currentValue > 0 else { return 0 }
        if let preset = presetValues.last(where: { $0 <= currentValue }) {
            return preset
        }
        if currentValue >= 1_000 {
            return (currentValue / 1_000) * 1_000
        }
        if currentValue >= 100 {
            return (currentValue / 100) * 100
        }
        return currentValue
    }
}

enum MilestoneShareTextBuilder {
    static func text(for share: RepoMilestoneShare) -> String {
        let metric = share.milestoneValue == 1 ? share.metric.singularName : share.metric.pluralName
        let countText = share.isRounded
            ? "\(share.formattedMilestoneValue)+ \(metric) (\(share.formattedCurrentValue) now)"
            : "\(share.formattedCurrentValue) \(metric)"
        return "\(share.repoDisplayName) just reached \(countText) on GitHub. Tracking it with Stargazer Bar: \(AppExternalLinks.projectPage.absoluteString)"
    }
}

enum MilestoneShareCardRenderer {
    static func image(for share: RepoMilestoneShare, size: CGFloat = 1200) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        drawBackground(in: bounds)
        drawAccentShapes(in: bounds)
        drawNumber(share.formattedMilestoneValue, metric: share.metric, in: bounds)
        drawFooter(share: share, in: bounds)
        return image
    }

    private static func drawBackground(in bounds: NSRect) {
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.015, green: 0.018, blue: 0.055, alpha: 1),
            NSColor(calibratedRed: 0.035, green: 0.028, blue: 0.12, alpha: 1),
            NSColor(calibratedRed: 0.01, green: 0.012, blue: 0.03, alpha: 1)
        ])
        gradient?.draw(in: bounds, angle: 35)

        NSColor(calibratedWhite: 1, alpha: 0.045).setFill()
        for index in 0..<42 {
            let x = CGFloat((index * 149) % 1120) + 28
            let y = CGFloat((index * 211) % 1050) + 54
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 4, height: 4)).fill()
        }
    }

    private static func drawAccentShapes(in bounds: NSRect) {
        let purple = NSColor(calibratedRed: 0.45, green: 0.18, blue: 1.0, alpha: 0.38)
        let blue = NSColor(calibratedRed: 0.0, green: 0.45, blue: 1.0, alpha: 0.34)
        let gold = NSColor(calibratedRed: 1.0, green: 0.66, blue: 0.12, alpha: 0.42)

        for (color, rect, angle) in [
            (purple, NSRect(x: -120, y: 120, width: 520, height: 76), -38.0),
            (blue, NSRect(x: 790, y: 130, width: 520, height: 54), 28.0),
            (gold, NSRect(x: 700, y: 770, width: 620, height: 58), 47.0)
        ] {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: angle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor(calibratedRed: 0.45, green: 0.25, blue: 1.0, alpha: 0.16).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 620, y: 580, width: 520, height: 520))
        ring.lineWidth = 2
        ring.stroke()
    }

    private static func drawNumber(_ number: String, metric: MilestoneMetric, in bounds: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let numberFont = NSFont.systemFont(ofSize: number.count > 4 ? 250 : 330, weight: .heavy)
        let numberRect = NSRect(x: 70, y: 530, width: bounds.width - 140, height: 370)
        number.draw(in: numberRect, withAttributes: [
            .font: numberFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: glow(color: metric == .stars ? .systemYellow : .systemBlue, blur: 26)
        ])

        let symbolRect = NSRect(x: bounds.midX - 92, y: 386, width: 184, height: 184)
        if let symbol = NSImage(systemSymbolName: metric.symbolName, accessibilityDescription: nil) {
            let configured = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 160, weight: .bold)
            ) ?? symbol
            configured.draw(
                in: symbolRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
    }

    private static func drawFooter(share: RepoMilestoneShare, in bounds: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let metric = share.milestoneValue == 1 ? share.metric.singularName : share.metric.pluralName
        let currentSuffix = share.isRounded ? " - \(share.formattedCurrentValue) now" : ""
        let title = "\(share.formattedMilestoneValue)+ GitHub \(metric)\(currentSuffix)"
        title.draw(in: NSRect(x: 110, y: 250, width: bounds.width - 220, height: 54), withAttributes: [
            .font: NSFont.systemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])

        share.repoDisplayName.draw(in: NSRect(x: 110, y: 196, width: bounds.width - 220, height: 40), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.78),
            .paragraphStyle: paragraph
        ])

        "Tracked with Stargazer Bar".draw(in: NSRect(x: 110, y: 138, width: bounds.width - 220, height: 32), withAttributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.58),
            .paragraphStyle: paragraph
        ])
    }

    private static func glow(color: NSColor, blur: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.62)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = .zero
        return shadow
    }
}
