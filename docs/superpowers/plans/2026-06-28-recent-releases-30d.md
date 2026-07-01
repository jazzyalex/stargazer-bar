# "Last 30 days" Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Last 30 days" section to the per-repo submenu showing recent-release adoption, growth, momentum, and cadence — all from already-fetched data.

**Architecture:** Mirror the Latest release feature: a `RecentReleasesSummary` (release-derived) built at poll time and persisted on `TrackedRepo`; stars/forks growth + momentum computed at menu-render from `trendPoints` via a `value(at:)` primitive; a formatter turns it into rows; a menu method renders them.

**Tech Stack:** Swift / AppKit (NSMenu), XCTest. macOS app `GHMenuStars` (product "Stargazer Bar"). No new dependencies, no new network calls.

## Global Constraints

- No new GitHub API calls; reuse the releases list and `trendPoints` already fetched/stored.
- Window is a fixed constant `ReleaseDynamics.recentWindowDays = 30`.
- New persisted fields decode with `decodeIfPresent` (backward compatible), like `latestRelease`.
- Build/test: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -quiet`. `.deriveddata-run` is build-only; never `open` a bundle from it.
- New files must be registered in `GHMenuStars.xcodeproj/project.pbxproj` (explicit references; the project has no synchronized groups). ID scheme: build files `10000000000000000000002X`, file refs `20000000000000000000002X`. Highest currently used is `…2A` (ReleaseDynamics.swift).
- Numbers render via `NumberFormatter.menuInteger`. Sentence case, no ALL CAPS.

---

## File structure

- `GHMenuStars/Services/ReleaseDynamics.swift` — add `recentWindowDays` constant + `value(in:at:keyPath:)`; refactor `starsSinceRelease`.
- `GHMenuStars/Models/RecentReleasesSummary.swift` — **new** Codable model.
- `GHMenuStars/GitHub/RecentReleasesSummaryBuilder.swift` — **new** derivation.
- `GHMenuStars/Models/RepoSnapshot.swift` + `Models/TrackedRepo.swift` + `Persistence/TrackedRepoStore.swift` — persist `recentReleases`.
- `GHMenuStars/Services/RepoPollingService.swift` — build the summary into the snapshot.
- `GHMenuStars/Services/Formatters.swift` — `RecentReleasesLineFormatter`.
- `GHMenuStars/StatusMenuBuilder.swift` — `addRecentReleasesItems`, called from `trendMenu`.

---

### Task 1: ReleaseDynamics — window constant, `value(at:)`, refactor

**Files:**
- Modify: `GHMenuStars/Services/ReleaseDynamics.swift`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift`

**Interfaces:**
- Produces: `ReleaseDynamics.recentWindowDays: Int` (= 30);
  `ReleaseDynamics.value(in points: [RepoTrendPoint], at date: Date, keyPath: KeyPath<RepoTrendPoint, Int>) -> Int?`
  (newest point with `date ≤ date`, else nil).
- `starsSinceRelease(trendPoints:currentStars:publishedAt:)` unchanged in behavior.

- [ ] **Step 1: Write the failing test**

Add to `ServiceLogicTests.swift`:

```swift
func testValueAtReturnsNearestPointAtOrBeforeDate() {
    let points = [
        RepoTrendPoint(date: Date(timeIntervalSince1970: 1_000_000), stars: 600, forks: 1),
        RepoTrendPoint(date: Date(timeIntervalSince1970: 1_400_000), stars: 623, forks: 3),
        RepoTrendPoint(date: Date(timeIntervalSince1970: 1_900_000), stars: 660, forks: 5)
    ]
    XCTAssertEqual(ReleaseDynamics.value(in: points, at: Date(timeIntervalSince1970: 1_500_000), keyPath: \.stars), 623)
    XCTAssertEqual(ReleaseDynamics.value(in: points, at: Date(timeIntervalSince1970: 1_500_000), keyPath: \.forks), 3)
    XCTAssertNil(ReleaseDynamics.value(in: points, at: Date(timeIntervalSince1970: 900_000), keyPath: \.stars))
    XCTAssertEqual(ReleaseDynamics.recentWindowDays, 30)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testValueAtReturnsNearestPointAtOrBeforeDate -quiet`
Expected: FAIL — `type 'ReleaseDynamics' has no member 'value'`.

- [ ] **Step 3: Add the constant + primitive, refactor `starsSinceRelease`**

In `ReleaseDynamics.swift`, add after `releaseFreshnessWindow`:

```swift
    static let recentWindowDays = 30

    static func value(in points: [RepoTrendPoint], at date: Date, keyPath: KeyPath<RepoTrendPoint, Int>) -> Int? {
        points.filter { $0.date <= date }.max(by: { $0.date < $1.date })?[keyPath: keyPath]
    }
```

Replace the body of `starsSinceRelease` with:

```swift
    static func starsSinceRelease(trendPoints: [RepoTrendPoint], currentStars: Int, publishedAt: Date) -> Int? {
        guard let baseline = value(in: trendPoints, at: publishedAt, keyPath: \.stars) else { return nil }
        return max(0, currentStars - baseline)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testValueAtReturnsNearestPointAtOrBeforeDate -only-testing:GHMenuStarsTests/ServiceLogicTests/testStarsSinceReleaseFromTrendPoints -quiet`
Expected: PASS (both — the refactor preserves `starsSinceRelease`).

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Services/ReleaseDynamics.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "refactor: add trend value(at:) primitive and 30-day window constant"
```

---

### Task 2: `RecentReleasesSummary` model + builder

**Files:**
- Create: `GHMenuStars/Models/RecentReleasesSummary.swift`
- Create: `GHMenuStars/GitHub/RecentReleasesSummaryBuilder.swift`
- Modify: `GHMenuStars.xcodeproj/project.pbxproj`
- Test: `GHMenuStarsTests/GitHubModelTests.swift`

**Interfaces:**
- Consumes: `GitHubRelease`, `ReleaseDynamics.recentWindowDays` (Task 1).
- Produces: `RecentReleasesSummary { releaseCount: Int; downloads: Int; totalDownloads: Int }`;
  `RecentReleasesSummaryBuilder.summary(from releases: [GitHubRelease], totalDownloads: Int, now: Date) -> RecentReleasesSummary?`
  (nil when there are no non-draft published releases at all).

- [ ] **Step 1: Write the failing tests**

Add to `GitHubModelTests.swift`:

```swift
func testRecentReleasesSummaryCountsWindowAndSumsDownloads() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let day = 24.0 * 60 * 60
    let inWindow1 = GitHubRelease(tagName: "v3", name: nil, publishedAt: now.addingTimeInterval(-5 * day),
        draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "a.dmg", downloadCount: 800)])
    let inWindow2 = GitHubRelease(tagName: "v2", name: nil, publishedAt: now.addingTimeInterval(-20 * day),
        draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "b.dmg", downloadCount: 300),
                                                   GitHubReleaseAsset(name: "b.zip", downloadCount: 100)])
    let outWindow = GitHubRelease(tagName: "v1", name: nil, publishedAt: now.addingTimeInterval(-40 * day),
        draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "c.dmg", downloadCount: 5000)])
    let draftInWindow = GitHubRelease(tagName: "v4", name: nil, publishedAt: now.addingTimeInterval(-1 * day),
        draft: true, prerelease: false, assets: [GitHubReleaseAsset(name: "d.dmg", downloadCount: 999)])
    let summary = RecentReleasesSummaryBuilder.summary(from: [inWindow1, inWindow2, outWindow, draftInWindow], totalDownloads: 6200, now: now)
    XCTAssertEqual(summary?.releaseCount, 2)
    XCTAssertEqual(summary?.downloads, 1200)
    XCTAssertEqual(summary?.totalDownloads, 6200)
}

func testRecentReleasesSummaryNilWhenNoPublishedReleases() {
    let draftOnly = GitHubRelease(tagName: "v1", name: nil, publishedAt: nil, draft: true, prerelease: false, assets: [])
    XCTAssertNil(RecentReleasesSummaryBuilder.summary(from: [draftOnly], totalDownloads: 0, now: Date()))
}

func testRecentReleasesSummaryZeroCountWhenReleasesAllOld() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let old = GitHubRelease(tagName: "v1", name: nil, publishedAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
        draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "a.dmg", downloadCount: 10)])
    let summary = RecentReleasesSummaryBuilder.summary(from: [old], totalDownloads: 10, now: now)
    XCTAssertEqual(summary?.releaseCount, 0)
    XCTAssertEqual(summary?.downloads, 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/GitHubModelTests/testRecentReleasesSummaryCountsWindowAndSumsDownloads -quiet`
Expected: FAIL — `cannot find 'RecentReleasesSummaryBuilder' in scope`.

- [ ] **Step 3: Create the model**

`GHMenuStars/Models/RecentReleasesSummary.swift`:

```swift
import Foundation

struct RecentReleasesSummary: Codable, Equatable {
    var releaseCount: Int
    var downloads: Int
    var totalDownloads: Int
}
```

- [ ] **Step 4: Create the builder**

`GHMenuStars/GitHub/RecentReleasesSummaryBuilder.swift`:

```swift
import Foundation

enum RecentReleasesSummaryBuilder {
    static func summary(from releases: [GitHubRelease], totalDownloads: Int, now: Date = Date()) -> RecentReleasesSummary? {
        let published = releases.compactMap { release -> (GitHubRelease, Date)? in
            guard !release.draft, let date = release.publishedAt else { return nil }
            return (release, date)
        }
        guard !published.isEmpty else { return nil }

        let windowStart = now.addingTimeInterval(-Double(ReleaseDynamics.recentWindowDays) * 24 * 60 * 60)
        let recent = published.filter { $0.1 >= windowStart }
        let downloads = recent.reduce(0) { total, entry in
            total + entry.0.assets.reduce(0) { $0 + $1.downloadCount }
        }
        return RecentReleasesSummary(releaseCount: recent.count, downloads: downloads, totalDownloads: totalDownloads)
    }
}
```

- [ ] **Step 5: Register both files in the Xcode project**

In `project.pbxproj`, add:
- In the PBXBuildFile section (before `/* End PBXBuildFile section */`):

```
		10000000000000000000002B /* RecentReleasesSummary.swift in Sources */ = {isa = PBXBuildFile; fileRef = 20000000000000000000002B /* RecentReleasesSummary.swift */; };
		10000000000000000000002C /* RecentReleasesSummaryBuilder.swift in Sources */ = {isa = PBXBuildFile; fileRef = 20000000000000000000002C /* RecentReleasesSummaryBuilder.swift */; };
```

- In the PBXFileReference section (before `/* End PBXFileReference section */`):

```
		20000000000000000000002B /* RecentReleasesSummary.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecentReleasesSummary.swift; sourceTree = "<group>"; };
		20000000000000000000002C /* RecentReleasesSummaryBuilder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecentReleasesSummaryBuilder.swift; sourceTree = "<group>"; };
```

- Append `20000000000000000000002B` to the **Models** group children (`700000000000000000000003`) and `20000000000000000000002C` to the **GitHub** group children (`700000000000000000000004`).
- Append `10000000000000000000002B, 10000000000000000000002C` to the app target's Sources build phase `files` list (`A00000000000000000000001`).

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/GitHubModelTests -quiet`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add GHMenuStars/Models/RecentReleasesSummary.swift GHMenuStars/GitHub/RecentReleasesSummaryBuilder.swift GHMenuStars.xcodeproj/project.pbxproj GHMenuStarsTests/GitHubModelTests.swift
git commit -m "feat: derive last-30-days release summary"
```

---

### Task 3: Persist + poll wiring

**Files:**
- Modify: `GHMenuStars/Models/RepoSnapshot.swift`, `Models/TrackedRepo.swift`, `Persistence/TrackedRepoStore.swift`, `Services/RepoPollingService.swift`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift`

**Interfaces:**
- Consumes: `RecentReleasesSummaryBuilder` (Task 2).
- Produces: `RepoSnapshot.recentReleases`, `TrackedRepo.recentReleases`.

- [ ] **Step 1: Write the failing test**

Add to `ServiceLogicTests.swift`:

```swift
func testApplySnapshotPersistsRecentReleases() {
    let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
    let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
    let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
    store.setTrackedRepo(repo)
    let recent = RecentReleasesSummary(releaseCount: 2, downloads: 500, totalDownloads: 900)
    let snapshot = RepoSnapshot(stars: 1, releaseDownloads: 900, forks: 0,
        checkedAt: Date(), repoETag: nil, releasesETag: nil, recentReleases: recent)
    _ = store.apply(snapshot: snapshot, to: repo.id)
    XCTAssertEqual(store.trackedRepos.first?.recentReleases?.releaseCount, 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testApplySnapshotPersistsRecentReleases -quiet`
Expected: FAIL — `incorrect argument label ... 'recentReleases:'`.

- [ ] **Step 3: Add `recentReleases` to `RepoSnapshot`**

In `RepoSnapshot.swift`, after `var latestRelease: LatestReleaseSummary? = nil`:

```swift
    var recentReleases: RecentReleasesSummary? = nil
```

- [ ] **Step 4: Add `recentReleases` to `TrackedRepo`**

In `TrackedRepo.swift`:
- After `var latestRelease: LatestReleaseSummary?` add: `var recentReleases: RecentReleasesSummary?`
- In `CodingKeys` after `case latestRelease` add: `case recentReleases`
- In `init(...)` after `latestRelease: LatestReleaseSummary? = nil,` add: `recentReleases: RecentReleasesSummary? = nil,`
- In the init body after `self.latestRelease = latestRelease` add: `self.recentReleases = recentReleases`
- In `init(from decoder:)` after the `latestRelease = try container.decodeIfPresent(...)` line add:
  `recentReleases = try container.decodeIfPresent(RecentReleasesSummary.self, forKey: .recentReleases)`

- [ ] **Step 5: Persist in `apply(snapshot:)`**

In `TrackedRepoStore.swift`, after the `if let latestRelease = snapshot.latestRelease { … }` block:

```swift
        if let recentReleases = snapshot.recentReleases {
            repo.recentReleases = recentReleases
        }
```

- [ ] **Step 6: Build the summary in the poller**

In `RepoPollingService.swift`, in the releases `do`/`catch` block, add a `var recentReleases: RecentReleasesSummary?` alongside `latestRelease` and set it in both branches:

```swift
            let downloads: Int
            var latestRelease: LatestReleaseSummary?
            var recentReleases: RecentReleasesSummary?
            do {
                let releasesResult = try await gitHubClient.fetchReleases(owner: repo.owner, name: repo.name, etag: repo.etagReleases)
                downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                latestRelease = LatestReleaseSummaryBuilder.summary(from: releasesResult.value, totalDownloads: downloads)
                recentReleases = RecentReleasesSummaryBuilder.summary(from: releasesResult.value, totalDownloads: downloads, now: Date())
                releasesETag = releasesResult.etag ?? releasesETag
                latestRateLimitState = releasesResult.rateLimitState ?? latestRateLimitState
            } catch GitHubError.notModified {
                downloads = repo.lastDownloads ?? 0
                latestRelease = nil
                recentReleases = nil
            }
```

Then add `recentReleases` to the `RepoSnapshot(...)` initializer (after `latestRelease: latestRelease`):

```swift
                latestRelease: latestRelease,
                recentReleases: recentReleases
            )
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -quiet`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add GHMenuStars/Models/RepoSnapshot.swift GHMenuStars/Models/TrackedRepo.swift GHMenuStars/Persistence/TrackedRepoStore.swift GHMenuStars/Services/RepoPollingService.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat: persist last-30-days release summary"
```

---

### Task 4: Formatter + menu section

**Files:**
- Modify: `GHMenuStars/Services/Formatters.swift`, `GHMenuStars/StatusMenuBuilder.swift`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift`

**Interfaces:**
- Consumes: `RecentReleasesSummary`, `TrackedRepo.recentReleases`/`trendPoints`/`lastStars`/`lastForks`, `ReleaseDynamics.value` + `recentWindowDays` + `sharePercent`.
- Produces: `RecentReleasesLineFormatter.rows(_:trendPoints:currentStars:currentForks:now:) -> [(image: String, text: String)]`; the redesigned submenu section.

- [ ] **Step 1: Write the failing formatter tests**

Add to `ServiceLogicTests.swift`:

```swift
func testRecentReleasesRowsFormatAllFour() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let day = 24.0 * 60 * 60
    let points = [
        RepoTrendPoint(date: now.addingTimeInterval(-65 * day), stars: 500, forks: 5),
        RepoTrendPoint(date: now.addingTimeInterval(-30 * day), stars: 540, forks: 7)
    ]
    let summary = RecentReleasesSummary(releaseCount: 3, downloads: 2_480, totalDownloads: 8_857)
    let rows = RecentReleasesLineFormatter.rows(summary, trendPoints: points, currentStars: 662, currentForks: 12, now: now).map(\.text)
    XCTAssertEqual(rows, [
        "3 releases · +122 ⭐ · +5 forks",
        "2,480 ↓ · ~83/day · 28% of all",
        "↑ vs prior 30d · +40 ⭐ · +2 forks",
        "~1 release / 10 days · avg 827 ↓/release"
    ])
}

func testRecentReleasesRowsGrowthOnlyWhenNoReleasesInWindow() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let day = 24.0 * 60 * 60
    let points = [RepoTrendPoint(date: now.addingTimeInterval(-40 * day), stars: 600, forks: 3)]
    let summary = RecentReleasesSummary(releaseCount: 0, downloads: 0, totalDownloads: 5_000)
    let rows = RecentReleasesLineFormatter.rows(summary, trendPoints: points, currentStars: 640, currentForks: 4, now: now).map(\.text)
    XCTAssertEqual(rows, ["+40 ⭐ · +1 fork"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testRecentReleasesRowsFormatAllFour -quiet`
Expected: FAIL — `cannot find 'RecentReleasesLineFormatter' in scope`.

- [ ] **Step 3: Add the formatter**

In `Formatters.swift` add:

```swift
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
        if let s = starsGained, s > 0 { line1.append("+\(fmt(s)) ⭐") }
        if let f = forksGained, f > 0 { line1.append("+\(fmt(f)) \(f == 1 ? "fork" : "forks")") }
        if !line1.isEmpty { rows.append((image: "shippingbox", text: line1.joined(separator: " · "))) }

        if summary.downloads > 0 {
            var line2 = "\(fmt(summary.downloads)) ↓ · ~\(fmt(rate(summary.downloads)))/day"
            if let share = ReleaseDynamics.sharePercent(downloads: summary.downloads, totalDownloads: summary.totalDownloads) {
                line2 += " · \(share)% of all"
            }
            rows.append((image: "arrow.down.circle", text: line2))
        }

        if let starsBase, let starsGained,
           let starsPrior = ReleaseDynamics.value(in: trendPoints, at: priorStart, keyPath: \.stars) {
            let priorStars = max(0, starsBase - starsPrior)
            let arrow = starsGained > priorStars ? "↑" : (starsGained < priorStars ? "↓" : "→")
            var line3 = ["\(arrow) vs prior \(ReleaseDynamics.recentWindowDays)d", "+\(fmt(priorStars)) ⭐"]
            if let forksBase, let forksPrior = ReleaseDynamics.value(in: trendPoints, at: priorStart, keyPath: \.forks) {
                let priorForks = max(0, forksBase - forksPrior)
                line3.append("+\(fmt(priorForks)) \(priorForks == 1 ? "fork" : "forks")")
            }
            rows.append((image: "chart.line.uptrend.xyaxis", text: line3.joined(separator: " · ")))
        }

        if summary.releaseCount > 0 {
            let days = max(1, Int((Double(ReleaseDynamics.recentWindowDays) / Double(summary.releaseCount)).rounded()))
            var line4 = summary.releaseCount == 1
                ? "1 release in \(ReleaseDynamics.recentWindowDays) days"
                : "~1 release / \(days) days"
            if summary.downloads > 0 {
                let avg = Int((Double(summary.downloads) / Double(summary.releaseCount)).rounded())
                line4 += " · avg \(fmt(avg)) ↓/release"
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
```

- [ ] **Step 4: Run formatter tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testRecentReleasesRowsFormatAllFour -only-testing:GHMenuStarsTests/ServiceLogicTests/testRecentReleasesRowsGrowthOnlyWhenNoReleasesInWindow -quiet`
Expected: PASS.

- [ ] **Step 5: Add the menu section**

In `StatusMenuBuilder.swift`, in `trendMenu`, after `addLatestReleaseItems(to: submenu, for: repo)` add:

```swift
        addRecentReleasesItems(to: submenu, for: repo)
```

Add the method next to `addLatestReleaseItems`:

```swift
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
        submenu.addItem(titleItem("Last 30 days"))
        for row in rows {
            submenu.addItem(titleItem(row.text, imageName: row.image))
        }
    }
```

- [ ] **Step 6: Write the menu test**

Add to `ServiceLogicTests.swift` (reuse the `buildMenu(for:)` helper):

```swift
func testMenuShowsLast30DaysSection() {
    let now = Date()
    let day = 24.0 * 60 * 60
    let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual,
        lastStars: 662, lastForks: 12,
        trendPoints: [
            RepoTrendPoint(date: now.addingTimeInterval(-65 * day), stars: 500, forks: 5),
            RepoTrendPoint(date: now.addingTimeInterval(-30 * day), stars: 540, forks: 7)
        ],
        recentReleases: RecentReleasesSummary(releaseCount: 3, downloads: 2_480, totalDownloads: 8_857))
    let menu = buildMenu(for: repo)
    XCTAssertNotNil(Self.menuItem(titled: "Last 30 days", in: menu))
    XCTAssertNotNil(Self.menuItem(containing: "↓/release", in: menu))
}
```

Note: the `TrackedRepo` initializer's parameter order is `... lastStars, lastDownloads, lastForks, ... trendPoints, trendRange, maintainerRadar, latestRelease, recentReleases, ...` — pass arguments in that declaration order.

- [ ] **Step 7: Run the full suite**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -quiet`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add GHMenuStars/Services/Formatters.swift GHMenuStars/StatusMenuBuilder.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat: add Last 30 days section to repo submenu"
```

---

## Self-review

- **Spec coverage:** releases-shipped + downloads + rate + share (Task 2 builder, Task 4 rows 1–2) ✓; stars/forks growth (Task 1 `value(at:)`, Task 4 row 1) ✓; momentum vs prior 30d with arrow (Task 4 row 3) ✓; cadence + avg per release (Task 4 row 4) ✓; release-scoped 30-day downloads (Task 2) ✓; gains clamp ≥0 (Task 4 `max(0, …)`) ✓; fixed-window constant, no stored `windowDays` (Task 1) ✓; gating — section hidden when `recentReleases == nil`, rows dropped when empty, downloads/cadence/momentum conditional (Task 4) ✓; persist like `latestRelease` (Task 3) ✓; no new API calls (reuses `fetchReleases` + `trendPoints`) ✓.
- **Placeholder scan:** none — every step has concrete code and commands.
- **Type consistency:** `RecentReleasesSummary` fields, `RecentReleasesSummaryBuilder.summary(from:totalDownloads:now:)`, `ReleaseDynamics.value(in:at:keyPath:)` + `recentWindowDays`, `RecentReleasesLineFormatter.rows(_:trendPoints:currentStars:currentForks:now:)`, and `RepoSnapshot.recentReleases` / `TrackedRepo.recentReleases` are used identically across tasks.
- **Verify at execution:** confirm the exact line of the `latestRelease` decode in `TrackedRepo.init(from:)` and the `latestRelease:` argument in the poller's `RepoSnapshot(...)` before inserting the sibling `recentReleases` lines (both exist from the release-dynamics work).
