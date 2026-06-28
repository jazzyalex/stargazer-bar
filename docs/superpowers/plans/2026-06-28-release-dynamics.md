# Release Dynamics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Latest release" block + release-relative activity to each repo's
submenu so a maintainer can see adoption, regressions, and growth after shipping.

**Architecture:** Reuse the releases list the poller already fetches. Decode more
of each release, derive a `LatestReleaseSummary`, persist it on `TrackedRepo`
(mirroring `maintainerRadar`), anchor the radar's activity window to a fresh
release, and redesign the menu section below the chart for density.

**Tech Stack:** Swift / AppKit (NSMenu), XCTest. macOS app `GHMenuStars`
(product name "Stargazer Bar"). No new dependencies, no new network calls.

## Global Constraints

- No new GitHub API calls; everything derives from the already-fetched repo,
  releases, stargazer, and fork data.
- `releaseFreshnessWindow` = 14 days (`60 * 60 * 24 * 14` seconds), a fixed constant.
- All new persisted fields decode with `decodeIfPresent` (backward compatible
  with stored JSON), exactly like `maintainerRadar`.
- Build/test with: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -quiet`. `.deriveddata-run` is a build-only path; never `open` a bundle from it.
- Tests live in `GHMenuStarsTests/`; reuse the existing `ServiceLogicTests` /
  `GitHubModelTests` helpers (`menuItem(titled:in:)`, `menuItem(containing:in:)`,
  `isFullyBold`, `hasBoldPrefix`).
- Numbers render via `NumberFormatter.menuInteger`. Sentence case, no ALL CAPS.

---

## File structure

- `GHMenuStars/GitHub/GitHubClient.swift` — expand `GitHubRelease`; add
  `releaseAnchor` param to `fetchMaintainerRadar`.
- `GHMenuStars/Models/LatestReleaseSummary.swift` — **new** Codable model.
- `GHMenuStars/GitHub/LatestReleaseSummaryBuilder.swift` — **new** derivation
  (mirrors `ReleaseDownloadAggregator.swift`).
- `GHMenuStars/Services/ReleaseDynamics.swift` — **new** pure helpers
  (freshness, daily rate, share, stars-since-release).
- `GHMenuStars/Models/RepoSnapshot.swift` — add `latestRelease`.
- `GHMenuStars/Models/TrackedRepo.swift` — add persisted `latestRelease`;
  add `activityAnchoredSince` to `RepoMaintainerRadar`.
- `GHMenuStars/Persistence/TrackedRepoStore.swift` — persist `latestRelease`.
- `GHMenuStars/Services/RepoPollingService.swift` — build summary, decide anchor,
  pass into radar + snapshot.
- `GHMenuStars/Services/Formatters.swift` — release line formatting helpers.
- `GHMenuStars/StatusMenuBuilder.swift` — redesigned section + release block;
  chart marker in `RepoTrendView`.

Tasks 1–5 are data/logic (independently mergeable). Tasks 6–7 are UI and depend
on 1–5.

---

### Task 1: Expand `GitHubRelease` decoding

**Files:**
- Modify: `GHMenuStars/GitHub/GitHubClient.swift:56-58` (the `GitHubRelease` struct)
- Test: `GHMenuStarsTests/GitHubModelTests.swift`

**Interfaces:**
- Produces: `GitHubRelease` with `tagName: String`, `name: String?`,
  `publishedAt: Date?`, `draft: Bool`, `prerelease: Bool`,
  `assets: [GitHubReleaseAsset]`. Memberwise init still available
  (e.g. `GitHubRelease(assets: [...])`) because Decodable is in an extension.

- [ ] **Step 1: Write the failing test**

Add to `GitHubModelTests.swift`:

```swift
func testReleaseDecodingReadsTagDateAndFlags() throws {
    let json = """
    [{"tag_name":"v0.3.1","name":"0.3.1","published_at":"2026-06-26T10:00:00Z",
      "draft":false,"prerelease":true,
      "assets":[{"name":"App-arm64.dmg","download_count":820}]}]
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let releases = try decoder.decode([GitHubRelease].self, from: json)
    XCTAssertEqual(releases.first?.tagName, "v0.3.1")
    XCTAssertEqual(releases.first?.name, "0.3.1")
    XCTAssertEqual(releases.first?.prerelease, true)
    XCTAssertEqual(releases.first?.draft, false)
    XCTAssertEqual(releases.first?.assets.first?.downloadCount, 820)
    XCTAssertNotNil(releases.first?.publishedAt)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/GitHubModelTests/testReleaseDecodingReadsTagDateAndFlags -quiet`
Expected: FAIL — `value of type 'GitHubRelease' has no member 'tagName'`.

- [ ] **Step 3: Replace the struct**

Replace `GitHubClient.swift:56-58` with:

```swift
struct GitHubRelease: Equatable {
    var tagName: String = ""
    var name: String?
    var publishedAt: Date?
    var draft: Bool = false
    var prerelease: Bool = false
    var assets: [GitHubReleaseAsset]
}

extension GitHubRelease: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decodeIfPresent(String.self, forKey: .tagName) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try container.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }
}
```

Putting `Decodable` in an extension keeps the synthesized memberwise init, so the
existing `testReleaseDownloadAggregation` (which builds `GitHubRelease(assets:)`)
keeps compiling.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/GitHubModelTests -quiet`
Expected: PASS — including the existing `testReleaseDownloadAggregation` and `testRepoJSONDecoding`.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/GitHub/GitHubClient.swift GHMenuStarsTests/GitHubModelTests.swift
git commit -m "feat: decode release tag, date, and flags"
```

---

### Task 2: `LatestReleaseSummary` model + builder

**Files:**
- Create: `GHMenuStars/Models/LatestReleaseSummary.swift`
- Create: `GHMenuStars/GitHub/LatestReleaseSummaryBuilder.swift`
- Test: `GHMenuStarsTests/GitHubModelTests.swift`

**Interfaces:**
- Consumes: `GitHubRelease` (Task 1).
- Produces:
  - `LatestReleaseSummary { tag: String; name: String?; publishedAt: Date; isPrerelease: Bool; downloads: Int; totalDownloads: Int; assets: [AssetCount] }`
    with `AssetCount { label: String; count: Int }`.
  - `LatestReleaseSummaryBuilder.summary(from releases: [GitHubRelease], totalDownloads: Int) -> LatestReleaseSummary?`

- [ ] **Step 1: Write the failing tests**

Add to `GitHubModelTests.swift`:

```swift
func testLatestReleaseSummaryPicksNewestPublishedNonDraft() {
    let old = GitHubRelease(tagName: "v0.2.0", name: nil,
        publishedAt: Date(timeIntervalSince1970: 1_000_000),
        draft: false, prerelease: false,
        assets: [GitHubReleaseAsset(name: "App-0.2.0-arm64.dmg", downloadCount: 100)])
    let draft = GitHubRelease(tagName: "v0.4.0", name: nil,
        publishedAt: Date(timeIntervalSince1970: 3_000_000),
        draft: true, prerelease: false, assets: [])
    let newest = GitHubRelease(tagName: "v0.3.1", name: "0.3.1",
        publishedAt: Date(timeIntervalSince1970: 2_000_000),
        draft: false, prerelease: true,
        assets: [GitHubReleaseAsset(name: "App-0.3.1-arm64.dmg", downloadCount: 820),
                 GitHubReleaseAsset(name: "App-0.3.1.zip", downloadCount: 410)])
    let summary = LatestReleaseSummaryBuilder.summary(from: [old, draft, newest], totalDownloads: 1_330)
    XCTAssertEqual(summary?.tag, "v0.3.1")
    XCTAssertEqual(summary?.isPrerelease, true)
    XCTAssertEqual(summary?.downloads, 1_230)
    XCTAssertEqual(summary?.totalDownloads, 1_330)
    XCTAssertEqual(summary?.assets.map(\.count), [820, 410])
    XCTAssertEqual(summary?.assets.map(\.label), ["arm64.dmg", "zip"])
}

func testLatestReleaseSummaryNilWhenNoPublishedRelease() {
    let draftOnly = GitHubRelease(tagName: "v1", name: nil, publishedAt: nil,
        draft: true, prerelease: false, assets: [])
    XCTAssertNil(LatestReleaseSummaryBuilder.summary(from: [draftOnly], totalDownloads: 0))
    XCTAssertNil(LatestReleaseSummaryBuilder.summary(from: [], totalDownloads: 0))
}
```

The common prefix `App-0.3.1-` / `App-0.3.1.` differs (`-` vs `.`), so the shared
prefix is `App-0.3.1`; stripping it leaves `-arm64.dmg` and `.zip`. After trimming
a leading separator the labels are `arm64.dmg` and `zip`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/GitHubModelTests/testLatestReleaseSummaryPicksNewestPublishedNonDraft -quiet`
Expected: FAIL — `cannot find 'LatestReleaseSummaryBuilder' in scope`.

- [ ] **Step 3: Create the model**

`GHMenuStars/Models/LatestReleaseSummary.swift`:

```swift
import Foundation

struct LatestReleaseSummary: Codable, Equatable {
    struct AssetCount: Codable, Equatable {
        var label: String
        var count: Int
    }

    var tag: String
    var name: String?
    var publishedAt: Date
    var isPrerelease: Bool
    var downloads: Int
    var totalDownloads: Int
    var assets: [AssetCount]
}
```

- [ ] **Step 4: Create the builder**

`GHMenuStars/GitHub/LatestReleaseSummaryBuilder.swift`:

```swift
import Foundation

enum LatestReleaseSummaryBuilder {
    static func summary(from releases: [GitHubRelease], totalDownloads: Int) -> LatestReleaseSummary? {
        let published = releases.compactMap { release -> (GitHubRelease, Date)? in
            guard !release.draft, let date = release.publishedAt else { return nil }
            return (release, date)
        }
        guard let (latest, publishedAt) = published.max(by: { $0.1 < $1.1 }) else { return nil }

        let downloads = latest.assets.reduce(0) { $0 + $1.downloadCount }
        let labels = shortLabels(for: latest.assets.map(\.name))
        let assets = zip(labels, latest.assets.map(\.downloadCount))
            .map { LatestReleaseSummary.AssetCount(label: $0.0, count: $0.1) }
            .sorted { $0.count > $1.count }
            .prefix(2)

        return LatestReleaseSummary(
            tag: latest.tagName,
            name: latest.name,
            publishedAt: publishedAt,
            isPrerelease: latest.prerelease,
            downloads: downloads,
            totalDownloads: totalDownloads,
            assets: Array(assets)
        )
    }

    static func shortLabels(for names: [String]) -> [String] {
        guard !names.isEmpty else { return [] }
        let prefix = commonPrefix(of: names)
        return names.map { name in
            var label = String(name.dropFirst(prefix.count))
            while let first = label.first, first == "-" || first == "." || first == "_" {
                label.removeFirst()
            }
            if label.isEmpty { label = name }
            if label.count > 16 {
                let parts = label.split(separator: "-").suffix(2).joined(separator: "-")
                label = parts.isEmpty ? String(label.suffix(16)) : parts
            }
            return label
        }
    }

    private static func commonPrefix(of names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            prefix = String(zip(prefix, name).prefix { $0.0 == $0.1 }.map(\.0))
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/GitHubModelTests -quiet`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add GHMenuStars/Models/LatestReleaseSummary.swift GHMenuStars/GitHub/LatestReleaseSummaryBuilder.swift GHMenuStarsTests/GitHubModelTests.swift
git commit -m "feat: derive latest release summary from releases list"
```

---

### Task 3: Release dynamics pure helpers

**Files:**
- Create: `GHMenuStars/Services/ReleaseDynamics.swift`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift`

**Interfaces:**
- Consumes: `RepoTrendPoint` (existing: `{ date: Date; stars: Int; forks: Int }`).
- Produces:
  - `ReleaseDynamics.releaseFreshnessWindow: TimeInterval`
  - `ReleaseDynamics.isFresh(publishedAt: Date, now: Date = Date()) -> Bool`
  - `ReleaseDynamics.dailyRate(downloads: Int, publishedAt: Date, now: Date = Date()) -> Int`
  - `ReleaseDynamics.sharePercent(downloads: Int, totalDownloads: Int) -> Int?`
  - `ReleaseDynamics.starsSinceRelease(trendPoints: [RepoTrendPoint], currentStars: Int, publishedAt: Date) -> Int?`

- [ ] **Step 1: Write the failing tests**

Add to `ServiceLogicTests.swift`:

```swift
func testReleaseDynamicsFreshnessAndMath() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    XCTAssertTrue(ReleaseDynamics.isFresh(publishedAt: now.addingTimeInterval(-60 * 60 * 24 * 3), now: now))
    XCTAssertFalse(ReleaseDynamics.isFresh(publishedAt: now.addingTimeInterval(-60 * 60 * 24 * 20), now: now))
    // 1000 downloads over 5 days -> 200/day
    XCTAssertEqual(ReleaseDynamics.dailyRate(downloads: 1000, publishedAt: now.addingTimeInterval(-60 * 60 * 24 * 5), now: now), 200)
    // younger than a day -> denominator floored to 1 day
    XCTAssertEqual(ReleaseDynamics.dailyRate(downloads: 50, publishedAt: now.addingTimeInterval(-60 * 60 * 2), now: now), 50)
    XCTAssertEqual(ReleaseDynamics.sharePercent(downloads: 380, totalDownloads: 1000), 38)
    XCTAssertNil(ReleaseDynamics.sharePercent(downloads: 0, totalDownloads: 0))
}

func testStarsSinceReleaseFromTrendPoints() {
    let publish = Date(timeIntervalSince1970: 1_500_000)
    let points = [
        RepoTrendPoint(date: Date(timeIntervalSince1970: 1_000_000), stars: 600, forks: 1),
        RepoTrendPoint(date: Date(timeIntervalSince1970: 1_400_000), stars: 623, forks: 1),
        RepoTrendPoint(date: Date(timeIntervalSince1970: 1_900_000), stars: 660, forks: 2)
    ]
    // nearest point at-or-before publish is 623 -> 665 - 623 = 42
    XCTAssertEqual(ReleaseDynamics.starsSinceRelease(trendPoints: points, currentStars: 665, publishedAt: publish), 42)
    // history starts after publish -> nil
    let late = [RepoTrendPoint(date: Date(timeIntervalSince1970: 1_600_000), stars: 640, forks: 1)]
    XCTAssertNil(ReleaseDynamics.starsSinceRelease(trendPoints: late, currentStars: 665, publishedAt: publish))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testReleaseDynamicsFreshnessAndMath -quiet`
Expected: FAIL — `cannot find 'ReleaseDynamics' in scope`.

- [ ] **Step 3: Create the helpers**

`GHMenuStars/Services/ReleaseDynamics.swift`:

```swift
import Foundation

enum ReleaseDynamics {
    static let releaseFreshnessWindow: TimeInterval = 60 * 60 * 24 * 14

    static func isFresh(publishedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(publishedAt) <= releaseFreshnessWindow
    }

    static func dailyRate(downloads: Int, publishedAt: Date, now: Date = Date()) -> Int {
        let days = max(1, now.timeIntervalSince(publishedAt) / (60 * 60 * 24))
        return Int((Double(downloads) / days).rounded())
    }

    static func sharePercent(downloads: Int, totalDownloads: Int) -> Int? {
        guard totalDownloads > 0 else { return nil }
        return Int((Double(downloads) / Double(totalDownloads) * 100).rounded())
    }

    static func starsSinceRelease(trendPoints: [RepoTrendPoint], currentStars: Int, publishedAt: Date) -> Int? {
        let baseline = trendPoints
            .filter { $0.date <= publishedAt }
            .max(by: { $0.date < $1.date })
        guard let baseline else { return nil }
        return max(0, currentStars - baseline.stars)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testReleaseDynamicsFreshnessAndMath -only-testing:GHMenuStarsTests/ServiceLogicTests/testStarsSinceReleaseFromTrendPoints -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Services/ReleaseDynamics.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat: add release dynamics math helpers"
```

---

### Task 4: Snapshot + persistence wiring

**Files:**
- Modify: `GHMenuStars/Models/RepoSnapshot.swift`
- Modify: `GHMenuStars/Models/TrackedRepo.swift` (add `latestRelease` field + CodingKey + init param + decode; add `activityAnchoredSince` to `RepoMaintainerRadar`)
- Modify: `GHMenuStars/Persistence/TrackedRepoStore.swift:123-125`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift`

**Interfaces:**
- Consumes: `LatestReleaseSummary` (Task 2).
- Produces: `RepoSnapshot.latestRelease: LatestReleaseSummary?`,
  `TrackedRepo.latestRelease: LatestReleaseSummary?`,
  `RepoMaintainerRadar.activityAnchoredSince: Date?`.

- [ ] **Step 1: Write the failing test**

Add to `ServiceLogicTests.swift`:

```swift
func testApplySnapshotPersistsLatestRelease() {
    let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
    let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
    let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
    store.setTrackedRepo(repo)
    let summary = LatestReleaseSummary(tag: "v0.3.1", name: "0.3.1",
        publishedAt: Date(timeIntervalSince1970: 2_000_000), isPrerelease: false,
        downloads: 1_230, totalDownloads: 1_330,
        assets: [LatestReleaseSummary.AssetCount(label: "arm64.dmg", count: 820)])
    let snapshot = RepoSnapshot(stars: 1, releaseDownloads: 1_330, forks: 0,
        checkedAt: Date(), repoETag: nil, releasesETag: nil,
        latestRelease: summary)
    _ = store.apply(snapshot: snapshot, to: repo.id)
    XCTAssertEqual(store.trackedRepos.first?.latestRelease?.tag, "v0.3.1")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testApplySnapshotPersistsLatestRelease -quiet`
Expected: FAIL — `incorrect argument label in call (have ... 'latestRelease:')`.

- [ ] **Step 3: Add `latestRelease` to `RepoSnapshot`**

In `RepoSnapshot.swift`, after `var maintainerRadar: RepoMaintainerRadar? = nil`:

```swift
    var latestRelease: LatestReleaseSummary? = nil
```

- [ ] **Step 4: Add `latestRelease` to `TrackedRepo`**

In `TrackedRepo.swift`:
- After `var maintainerRadar: RepoMaintainerRadar?` (line 249) add:
  `var latestRelease: LatestReleaseSummary?`
- In `CodingKeys` after `case maintainerRadar` (line 274) add: `case latestRelease`
- In `init(...)` after `maintainerRadar: RepoMaintainerRadar? = nil,` (line 300) add:
  `latestRelease: LatestReleaseSummary? = nil,`
- In the init body after `self.maintainerRadar = maintainerRadar` (line 324) add:
  `self.latestRelease = latestRelease`
- In `init(from decoder:)` after the `maintainerRadar = try container.decodeIfPresent(...)` line (line 351) add:
  `latestRelease = try container.decodeIfPresent(LatestReleaseSummary.self, forKey: .latestRelease)`

- [ ] **Step 5: Add `activityAnchoredSince` to `RepoMaintainerRadar`**

In `TrackedRepo.swift`, `struct RepoMaintainerRadar` (line 14): after
`var activityWindow: MaintainerRadarActivityWindow?` (line 20) add:

```swift
    var activityAnchoredSince: Date? = nil
```

`RepoMaintainerRadar` uses synthesized Codable; a property with a default value
keeps the existing memberwise init working for the call site in
`GitHubClient.fetchMaintainerRadar`. Confirm it also has a custom `init(from:)`;
if so, add `activityAnchoredSince = try container.decodeIfPresent(Date.self, forKey: .activityAnchoredSince)` and the matching CodingKey. (Read the struct's body first — if Codable is synthesized, no further edits are needed.)

- [ ] **Step 6: Persist in `apply(snapshot:)`**

In `TrackedRepoStore.swift`, after the `if let maintainerRadar` block (line 123-125):

```swift
        if let latestRelease = snapshot.latestRelease {
            repo.latestRelease = latestRelease
        }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests -quiet`
Expected: PASS (all ServiceLogicTests, confirming no decode regression).

- [ ] **Step 8: Commit**

```bash
git add GHMenuStars/Models/RepoSnapshot.swift GHMenuStars/Models/TrackedRepo.swift GHMenuStars/Persistence/TrackedRepoStore.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat: persist latest release summary on tracked repo"
```

---

### Task 5: Poll wiring + radar anchoring

**Files:**
- Modify: `GHMenuStars/GitHub/GitHubClient.swift:272-333` (`fetchMaintainerRadar`)
- Modify: `GHMenuStars/Services/RepoPollingService.swift:148-183` (`refresh`)
- Test: `GHMenuStarsTests/GitHubModelTests.swift`

**Interfaces:**
- Consumes: `LatestReleaseSummaryBuilder` (Task 2), `ReleaseDynamics` (Task 3),
  `RepoSnapshot.latestRelease` (Task 4).
- Produces: `fetchMaintainerRadar(owner:name:activityWindow:releaseAnchor:now:)`
  where a non-nil `releaseAnchor` overrides the activity start and sets
  `radar.activityAnchoredSince`.

- [ ] **Step 1: Write the failing test**

Add to `GitHubModelTests.swift` (mirror the existing
`testMaintainerRadarFetchesActivityWindowCounts` setup, which stubs the URL
session — reuse that test's `GitHubClient` construction and stub helper):

```swift
func testMaintainerRadarAnchorsToReleaseDate() async {
    // Reuse the same stubbed session/client pattern as
    // testMaintainerRadarFetchesActivityWindowCounts.
    let anchor = Date(timeIntervalSince1970: 1_500_000)
    let radar = await makeStubbedRadarClient().fetchMaintainerRadar(
        owner: "owner", name: "repo",
        activityWindow: .oneDay,
        releaseAnchor: anchor,
        now: Date(timeIntervalSince1970: 2_000_000)
    )
    XCTAssertEqual(radar.activityAnchoredSince, anchor)
}
```

If no shared stub helper exists, factor the existing test's stub into a
`makeStubbedRadarClient()` helper in this test file and reuse it here.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/GitHubModelTests/testMaintainerRadarAnchorsToReleaseDate -quiet`
Expected: FAIL — `extra argument 'releaseAnchor' in call`.

- [ ] **Step 3: Add the `releaseAnchor` parameter**

In `GitHubClient.swift`, change the `fetchMaintainerRadar` signature (line 272-277) to:

```swift
    func fetchMaintainerRadar(
        owner: String,
        name: String,
        activityWindow: MaintainerRadarActivityWindow,
        releaseAnchor: Date? = nil,
        now: Date = Date()
    ) async -> RepoMaintainerRadar {
        let activityStart = releaseAnchor ?? activityWindow.startDate(now: now)
```

(Replace the existing `let activityStart = activityWindow.startDate(now: now)` line.)
Then in the returned `RepoMaintainerRadar(...)` (line 322-332) add:

```swift
            activityAnchoredSince: releaseAnchor,
```

immediately after the `activityWindow:` argument. Keep the existing
`activityWindow: activityStart == nil ? nil : activityWindow` line as-is.

- [ ] **Step 4: Wire the poller**

In `RepoPollingService.swift`, change the releases `do/catch` (line 148-156) so the
summary is computed and a `latestRelease` value is available afterward:

```swift
            let downloads: Int
            var latestRelease: LatestReleaseSummary?
            do {
                let releasesResult = try await gitHubClient.fetchReleases(owner: repo.owner, name: repo.name, etag: repo.etagReleases)
                downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                latestRelease = LatestReleaseSummaryBuilder.summary(from: releasesResult.value, totalDownloads: downloads)
                releasesETag = releasesResult.etag ?? releasesETag
                latestRateLimitState = releasesResult.rateLimitState ?? latestRateLimitState
            } catch GitHubError.notModified {
                downloads = repo.lastDownloads ?? 0
                latestRelease = nil
            }
```

Then, before the `async let maintainerRadar` (line 165), compute the anchor from the
effective latest release (fresh new summary, else the persisted one):

```swift
            let effectiveRelease = latestRelease ?? repo.latestRelease
            let releaseAnchor = effectiveRelease.flatMap {
                ReleaseDynamics.isFresh(publishedAt: $0.publishedAt, now: checkedAt) ? $0.publishedAt : nil
            }
```

Pass it into the radar call:

```swift
            async let maintainerRadar = gitHubClient.fetchMaintainerRadar(
                owner: repo.owner,
                name: repo.name,
                activityWindow: settingsStore.settings.maintainerRadarActivityWindow,
                releaseAnchor: releaseAnchor,
                now: checkedAt
            )
```

And add `latestRelease` to the `RepoSnapshot(...)` initializer (after `maintainerRadar: radarSnapshot`):

```swift
                maintainerRadar: radarSnapshot,
                latestRelease: latestRelease
            )
```

Releases are fetched (line 148-156) before the radar `async let` (line 165), so the
anchor is always available — no reordering needed.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -quiet`
Expected: `** TEST SUCCEEDED **` (full suite — confirms the poller still compiles and all model tests pass).

- [ ] **Step 6: Commit**

```bash
git add GHMenuStars/GitHub/GitHubClient.swift GHMenuStars/Services/RepoPollingService.swift GHMenuStarsTests/GitHubModelTests.swift
git commit -m "feat: anchor radar to fresh release and snapshot summary"
```

---

### Task 6: Menu redesign — density, release block, since-line, footer

**Files:**
- Modify: `GHMenuStars/Services/Formatters.swift` (add `ReleaseLineFormatter`)
- Modify: `GHMenuStars/StatusMenuBuilder.swift` (`trendMenu`, replace `addMaintainerRadarItems`, add `addLatestReleaseItems`)
- Test: `GHMenuStarsTests/ServiceLogicTests.swift`

**Interfaces:**
- Consumes: `TrackedRepo.latestRelease`, `RepoMaintainerRadar.activityAnchoredSince`,
  `ReleaseDynamics` (Task 3).
- Produces: the redesigned per-repo submenu.

Design rules (from the spec): hide zero rows; collapse the healthy state into one
muted footer line; one packed `Since <tag>`/`Last <window>` activity line; a
"Latest release" block; assemble the footer from conditional segments.

- [ ] **Step 1: Write the release-line formatter test**

Add to `ServiceLogicTests.swift`:

```swift
func testReleaseLineFormatterPacksAdoption() {
    let summary = LatestReleaseSummary(tag: "v0.3.1", name: "0.3.1",
        publishedAt: Date(timeIntervalSince1970: 2_000_000 - 60 * 60 * 24 * 5),
        isPrerelease: false, downloads: 1_000, totalDownloads: 2_631,
        assets: [LatestReleaseSummary.AssetCount(label: "arm64.dmg", count: 820),
                 LatestReleaseSummary.AssetCount(label: "zip", count: 410)])
    let now = Date(timeIntervalSince1970: 2_000_000)
    XCTAssertEqual(
        ReleaseLineFormatter.adoptionLine(summary, now: now),
        "1,000 ↓ · ~200/day · 38% of all"
    )
    XCTAssertEqual(
        ReleaseLineFormatter.assetLine(summary),
        "arm64.dmg 820 · zip 410"
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testReleaseLineFormatterPacksAdoption -quiet`
Expected: FAIL — `cannot find 'ReleaseLineFormatter' in scope`.

- [ ] **Step 3: Add the formatter**

In `Formatters.swift` add:

```swift
enum ReleaseLineFormatter {
    static func adoptionLine(_ summary: LatestReleaseSummary, now: Date = Date()) -> String {
        let downloads = NumberFormatter.menuInteger.string(from: NSNumber(value: summary.downloads)) ?? "\(summary.downloads)"
        let rate = ReleaseDynamics.dailyRate(downloads: summary.downloads, publishedAt: summary.publishedAt, now: now)
        let rateText = NumberFormatter.menuInteger.string(from: NSNumber(value: rate)) ?? "\(rate)"
        var line = "\(downloads) ↓ · ~\(rateText)/day"
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
```

- [ ] **Step 4: Run formatter test to verify it passes**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -only-testing:GHMenuStarsTests/ServiceLogicTests/testReleaseLineFormatterPacksAdoption -quiet`
Expected: PASS.

- [ ] **Step 5: Insert the "Latest release" block in `trendMenu`**

In `StatusMenuBuilder.swift`, in `trendMenu` (line 115-125) after
`submenu.addItem(trendItem(for: repo))` and before the separator that precedes the
radar, insert:

```swift
        addLatestReleaseItems(to: submenu, for: repo)
```

Add the method (near `addMaintainerRadarItems`):

```swift
    private func addLatestReleaseItems(to submenu: NSMenu, for repo: TrackedRepo) {
        guard let release = repo.latestRelease else { return }
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(titleItem("Latest release"))
        let age = RelativeDateTimeFormatter.menu.string(for: release.publishedAt) ?? "recently"
        let tagLine = "\(release.tag) · \(age)" + (release.isPrerelease ? " · pre" : "")
        submenu.addItem(titleItem(tagLine, imageName: "tag"))
        submenu.addItem(titleItem(ReleaseLineFormatter.adoptionLine(release), imageName: "arrow.down.circle"))
        if let assetLine = ReleaseLineFormatter.assetLine(release) {
            submenu.addItem(titleItem(assetLine, imageName: "shippingbox"))
        }
    }
```

- [ ] **Step 6: Rewrite `addMaintainerRadarItems` for density**

Replace the body of `addMaintainerRadarItems` (line 189-272) with the version
below. It (a) keeps the prominent CI-failing row, (b) builds one packed activity
line labeled `Since <tag>` (when `activityAnchoredSince` is set) or
`Last <window>`, dropping zero parts, (c) shows the open-state row only for
non-zero metrics, (d) assembles a single muted footer from conditional segments.

```swift
    private func addMaintainerRadarItems(to submenu: NSMenu, for repo: TrackedRepo, target: StatusItemController) {
        guard let radar = repo.maintainerRadar, radar.hasData else {
            submenu.addItem(titleItem("Check Now to load radar", imageName: "arrow.clockwise"))
            submenu.addItem(discussionsItem(for: repo, target: target))
            return
        }
        submenu.addItem(NSMenuItem.separator())

        let ciFailing = radar.latestFailedWorkflow
        if let workflow = ciFailing {
            submenu.addItem(urlItem(
                "CI failing: \(workflow.name)",
                imageName: "xmark.circle.fill",
                url: URL(string: workflow.url) ?? gitHubURL(for: repo, path: "/actions"),
                target: target
            ))
        }

        // Packed activity line: commits · new PRs · new issues · +stars
        let anchored = radar.activityAnchoredSince != nil
        let since = radar.activityAnchoredSince ?? settingsStore.settings.maintainerRadarActivityWindow.startDate(now: radar.checkedAt)
        let label = anchored
            ? "Since \(repo.latestRelease?.tag ?? "release")"
            : "Last \(settingsStore.settings.maintainerRadarActivityWindow.menuLabel.replacingOccurrences(of: "last ", with: ""))"
        var activityParts: [String] = []
        if let commits = radar.recentCommits, commits > 0 { activityParts.append("\(Self.formattedCount(commits)) commits") }
        if let prs = radar.newPullRequests, prs > 0 { activityParts.append("\(Self.formattedCount(prs)) new \(prs == 1 ? "PR" : "PRs")") }
        if let issues = radar.newIssues, issues > 0 { activityParts.append("\(Self.formattedCount(issues)) new \(issues == 1 ? "issue" : "issues")") }
        if let release = repo.latestRelease,
           let stars = ReleaseDynamics.starsSinceRelease(trendPoints: repo.trendPoints, currentStars: repo.lastStars ?? 0, publishedAt: release.publishedAt),
           stars > 0 {
            activityParts.append("+\(Self.formattedCount(stars)) ⭐")
        }
        if !activityParts.isEmpty {
            submenu.addItem(titleItem(label, imageName: nil))
            submenu.addItem(urlItem(
                activityParts.joined(separator: " · "),
                imageName: "chart.line.uptrend.xyaxis",
                url: gitHubURL(for: repo, path: "/commits"),
                target: target
            ))
        }

        // Open-state row: only non-zero metrics.
        var openParts: [String] = []
        if let openPRs = radar.openPullRequests, openPRs > 0 { openParts.append("\(Self.formattedCount(openPRs)) open \(openPRs == 1 ? "PR" : "PRs")") }
        if let unanswered = radar.unansweredIssues, unanswered > 0 { openParts.append("\(Self.formattedCount(unanswered)) need first reply") }
        if !openParts.isEmpty {
            submenu.addItem(urlItem(
                openParts.joined(separator: " · "),
                imageName: "tray",
                url: gitHubURL(for: repo, path: "/issues", query: "is:issue is:open comments:0"),
                target: target
            ))
        }

        // Muted footer: CI clear (when passing) · nothing open (when none) · updated.
        var footerParts: [String] = []
        if ciFailing == nil, radar.workflowChecked { footerParts.append("CI clear") }
        if openParts.isEmpty { footerParts.append("nothing open") }
        footerParts.append("updated \(RelativeDateTimeFormatter.menu.string(for: radar.checkedAt) ?? "recently")")
        submenu.addItem(titleItem(footerParts.joined(separator: " · ")))
        submenu.addItem(discussionsItem(for: repo, target: target))
    }
```

Note: `MaintainerRadarActivityWindow.menuLabel` already exists (used at line 209).
If its value isn't shaped like "last 24h", read its definition and adjust the
`label` fallback string to produce `Last 24h`. The `· Open on GitHub` row remains
added by `trendMenu` via `openRepoItem` (line 123) — leave that call in place.

- [ ] **Step 7: Write the menu behavior tests**

Add to `ServiceLogicTests.swift` two tests modeled on
`testStatusMenuKeepsZeroRadarCountsRegular` (reuse its store/controller/menu
construction boilerplate):

```swift
func testMenuHidesZeroOpenRowsAndShowsReleaseBlock() {
    // Build a repo with all-zero radar counts + a latest release summary.
    // Assert: no "0 open PRs" item exists; a "Latest release" item exists;
    // the footer item contains "nothing open".
    // ... (construct repo with maintainerRadar all-zero + latestRelease,
    //      build menu via StatusMenuBuilder, then:)
    XCTAssertNil(Self.menuItem(titled: "0 open PRs", in: menu))
    XCTAssertNotNil(Self.menuItem(titled: "Latest release", in: menu))
    XCTAssertNotNil(Self.menuItem(containing: "nothing open", in: menu))
}

func testMenuLabelsActivitySinceReleaseWhenAnchored() {
    // Build a repo whose maintainerRadar has activityAnchoredSince set,
    // recentCommits = 3, latestRelease.tag = "v0.3.1".
    // Assert a caption item titled "Since v0.3.1" exists.
    XCTAssertNotNil(Self.menuItem(titled: "Since v0.3.1", in: menu))
}
```

Fill in the construction blocks by copying the boilerplate from
`testStatusMenuKeepsZeroRadarCountsRegular` (lines 556-598) and setting the repo's
`maintainerRadar` (with `activityAnchoredSince`) and `latestRelease` fields.

- [ ] **Step 8: Run the full suite**

Run: `xcodebuild test -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -quiet`
Expected: `** TEST SUCCEEDED **`. If `testStatusMenuKeepsZeroRadarCountsRegular`
now fails because the row titles changed (it asserts on `"0 new PRs last 24h"`
etc. which no longer render), update that test to assert those zero rows are
absent (`XCTAssertNil(Self.menuItem(titled: "0 new PRs last 24h", in: menu))`),
since suppression is now the intended behavior.

- [ ] **Step 9: Commit**

```bash
git add GHMenuStars/Services/Formatters.swift GHMenuStars/StatusMenuBuilder.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat: redesign repo submenu with release block and dense radar"
```

---

### Task 7: Release marker on the trend chart

**Files:**
- Modify: `GHMenuStars/StatusMenuBuilder.swift` (`trendItem`, `RepoTrendView`)

**Interfaces:**
- Consumes: `TrackedRepo.latestRelease.publishedAt`.
- Produces: a `▼` marker drawn at the release date inside the plot.

- [ ] **Step 1: Pass the release date into the view**

In `trendItem` (line 127-131), pass the date:

```swift
        item.view = RepoTrendView(repo: repo, trendRange: settingsStore.settings.repoTrendRange, releaseDate: repo.latestRelease?.publishedAt)
```

In `RepoTrendView`, add a stored property and init param:

```swift
    private let releaseDate: Date?

    init(repo: TrackedRepo, trendRange: RepoTrendRange, releaseDate: Date? = nil) {
        self.repo = repo
        self.trendRange = trendRange
        self.releaseDate = releaseDate
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 142))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
```

- [ ] **Step 2: Draw the marker**

In `draw(_:)`, after `drawLine(... \.forks ...)` (line 435) and before
`drawRangeLabels(in: plot)` (line 436), add:

```swift
        drawReleaseMarker(in: plot, start: start, end: end)
```

Add the method:

```swift
    private func drawReleaseMarker(in plot: NSRect, start: Date, end: Date) {
        guard let releaseDate, releaseDate >= start, releaseDate <= end else { return }
        let x = xPosition(for: releaseDate, in: plot, start: start, end: end)
        NSColor.tertiaryLabelColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: plot.minY))
        line.line(to: NSPoint(x: x, y: plot.maxY))
        line.lineWidth = 1
        let dash: [CGFloat] = [2, 2]
        line.setLineDash(dash, count: 2, phase: 0)
        line.stroke()

        NSColor.secondaryLabelColor.setFill()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: x - 4, y: plot.maxY + 6))
        marker.line(to: NSPoint(x: x + 4, y: plot.maxY + 6))
        marker.line(to: NSPoint(x: x, y: plot.maxY + 1))
        marker.close()
        marker.fill()
    }
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild build -scheme GHMenuStars -destination 'platform=macOS' -derivedDataPath .deriveddata-run -quiet`
Expected: build succeeds (exit 0). Then the user launches the app (Xcode / normal
flow) and confirms the `▼` marker appears on a repo with a recent release. Per
the project workflow: **I build, the user runs it** — do not `open` the
`.deriveddata-run` bundle.

- [ ] **Step 4: Commit**

```bash
git add GHMenuStars/StatusMenuBuilder.swift
git commit -m "feat: mark the release date on the trend chart"
```

---

## Self-review

- **Spec coverage:** adoption (Task 2 summary, Task 6 adoption/asset lines) ✓;
  regressions — issues since release (Task 5 anchor + Task 6 packed line) ✓;
  growth — stars since release (Task 3 + Task 6) and chart marker (Task 7) ✓;
  density rules — hide zeros, one window caption, packed line, conditional footer
  (Task 6) ✓; freshness anchoring (Task 3 + 5) ✓; graceful absence — block hidden
  when `latestRelease == nil` (Task 6 guard) ✓; model changes (Tasks 1, 4) ✓;
  no new API calls (reuses `fetchReleases`) ✓.
- **Placeholders:** Task 5 and Task 6/7 tests reference reusing existing
  stub/boilerplate rather than re-pasting it — the referenced code exists at the
  cited line ranges; copy it verbatim when implementing. No "TBD"/"handle edge
  cases" left.
- **Type consistency:** `LatestReleaseSummary` fields, `AssetCount`,
  `LatestReleaseSummaryBuilder.summary(from:totalDownloads:)`,
  `ReleaseDynamics.*`, `ReleaseLineFormatter.adoptionLine/assetLine`,
  `fetchMaintainerRadar(..., releaseAnchor:, now:)`,
  `RepoMaintainerRadar.activityAnchoredSince`, and `RepoSnapshot.latestRelease`
  are used with identical signatures across tasks.
- **Open verification:** the exact text of `MaintainerRadarActivityWindow.menuLabel`
  must be checked in Task 6 to produce `Last 24h`; and `RepoMaintainerRadar`'s
  Codable shape (synthesized vs custom `init(from:)`) must be checked in Task 4.
  Both are flagged inline as read-first steps.
