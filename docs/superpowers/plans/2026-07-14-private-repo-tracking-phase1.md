# Private Repo Tracking (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Stargazer Bar track private GitHub repositories using a user-supplied fine-grained personal access token, with the maintainer radar as the metric instead of stars.

**Architecture:** A second Keychain entry stores the PAT separately from the OAuth token. A new `@MainActor final class GitHubRepoAccess` owns per-repo token selection: it tries the ambient (OAuth/anonymous) token first, retries once with the PAT on a 404, and treats a 401 from the PAT as "PAT is dead" for the whole session. Existing `GitHubClient` methods gain a defaulted `optionalAuthToken` parameter so public-repo behaviour stays byte-identical. The two `guard !repoResult.value.private` lines that reject private repos are deleted, and `isPrivate` is persisted on `TrackedRepo`, always refreshed from a successful response.

**Tech Stack:** Swift 5, SwiftUI + AppKit, XCTest, Xcode project (no SPM for app code), Sparkle 2.9.1, GitHub REST API v3 (`2022-11-28`).

## Global Constraints

- **Phase 1 is an internal milestone.** It ships no user-visible feature. Main must stay releasable at every task boundary — a 0.5.x hotfix may cut from main at any time.
- **The PAT Settings section is behind `AppSettings.enablePrivateRepos`, default `false`.** Flipped on in phase 2. With the flag off, a build cut from main must be indistinguishable from today.
- **Public repo tracking must be byte-for-byte unchanged** for a user who never adds a PAT. `testPublicRepoFetchDoesNotReadToken` and `testPublicRepoFetchUsesOptionalTokenWhenAvailable` are the regression guards and **must keep passing untouched** — do not "fix" them.
- **Phase 1 must not advertise commit velocity in any UI copy.** The radar's `recentCommits` under-reports on feature-branch repos (`/commits` is default-branch-only); the fix is phase 2.
- **Suppress by metric, never by code block.** The sound and celebration blocks fire on downloads too; blanket-gating them on `!isPrivate` silently kills download celebrations private repos are entitled to.
- Repo cap stays 5 (`TrackedRepoStore.maximumTrackedRepos`).
- OAuth device-flow scope stays `public_repo`. Do not widen it.
- Never persist auth state (the latches are in-memory only).
- Never read the Keychain to diff secrets.
- Test command: `xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:<filter>`
- **`.deriveddata-test` is for tests ONLY.** Never `open` an app bundle built there — `xcodebuild test` re-signs the bundle and produces a healthy-but-invisible process with no menu bar item. Use `.deriveddata-run` to build something launchable.
- `timeout` is not installed on this machine. Do not use it in commands.
- Visual QA is done by the human, not by driving the app from the CLI.

---

## File Structure

**Created:**

| File | Single responsibility |
|---|---|
| `GHMenuStars/GitHub/GitHubRepoAccess.swift` | Per-repo token selection: which token to try, when to retry, when to give up. Owns both in-memory latches. The only place that decides PAT-vs-OAuth. |
| `GHMenuStars/Settings/GitHubAuthSettingsView.swift` | Both GitHub auth affordances (OAuth sign-in, PAT paste) extracted out of the 911-line `SettingsView`. |
| `GHMenuStarsTests/GitHubRepoAccessTests.swift` | Resolution rule, both latches, 304 handling, 403 passthrough. |
| `GHMenuStarsTests/Support/MockURLProtocol.swift` | The existing stub from `GitHubModelTests.swift:541`, moved out and made internal so more than one test file can use it, plus a `handler` hook for sequenced responses. |

**Modified:**

| File | Change |
|---|---|
| `GHMenuStars/Persistence/KeychainTokenStore.swift` | `account` becomes a defaulted `var`; PAT service + helpers. |
| `GHMenuStars/Persistence/SettingsStore.swift` | `enablePrivateRepos` flag. |
| `GHMenuStars/Models/TrackedRepo.swift` | `isPrivate` property + decode. |
| `GHMenuStars/Models/RepoSnapshot.swift` | `isPrivate` field. |
| `GHMenuStars/Persistence/TrackedRepoStore.swift` | Carry `isPrivate` through upsert + apply; ETag reset on flip; `clearAllETags()`. |
| `GHMenuStars/GitHub/GitHubClient.swift` | `optionalAuthToken` on `fetchRepo`/`fetchReleases`/`fetchMaintainerRadar`; error copy. |
| `GHMenuStars/Services/RepoPollingService.swift` | Delete guard; route via `GitHubRepoAccess`; thread winning token; skip stargazer/fork fetches; per-metric suppressions. |
| `GHMenuStars/Services/Formatters.swift` | `RepoMilestoneShare.make` returns nil for private repos. |
| `GHMenuStars/AppDelegate.swift` | Construct `GitHubRepoAccess`; inject into `RepoPollingService`. |
| `GHMenuStars/PreferencesWindow.swift` | Carry the access object through to `SettingsView`. |
| `GHMenuStars/SettingsView.swift` | Delete guard; route via `GitHubRepoAccess`; `backfillDetails` privacy-aware; `RepositoryRow` private shape; shrink via extraction. |
| `GHMenuStars/StatusMenuBuilder.swift` | Private repo line shape; drop trend submenu for private; copy at `:14`. |

**Dependency order.** Tasks 1–4 are leaf changes with no dependencies and leave main releasable on their own. Task 5 (`GitHubRepoAccess`) consumes 1 and 4. Tasks 6–7 extend 5. Task 8 wires 5 into the app. Tasks 9–12 consume the wiring. Task 13 (`clearAllETags`) is a leaf that Task 14 calls, so it precedes it. Do them in order — each task ends green and leaves main releasable.

---

### Task 1: Keychain PAT store

**Files:**
- Modify: `GHMenuStars/Persistence/KeychainTokenStore.swift:11-25`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `KeychainTokenStore.gitHubPATService: String` = `"StargazerBar.GitHubPAT"`
  - `KeychainTokenStore.gitHubPATStore() -> KeychainTokenStore`
  - `KeychainTokenStore.loadGitHubPAT() -> String?`
  - `KeychainTokenStore.hasGitHubPAT() -> Bool`
  - `KeychainTokenStore.account: String` (defaulted `var`, memberwise-init position **2 of 3**: `init(service:account:copyMatching:)`)

**Critical ordering detail:** `account` must be declared **before** `copyMatching`. `ServiceLogicTests.swift:1023` constructs the store with a **trailing closure** binding to `copyMatching`; a trailing closure only binds to the *last* parameter, so putting `account` last breaks that test's compilation. Also, `account` must be a `var` with a default, not a `let` with an initial value — a `let` with an initial value is excluded from the synthesized memberwise init entirely, so `KeychainTokenStore(service:account:)` would not compile.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/ServiceLogicTests.swift`, inside the existing test class:

```swift
func testPATStoreUsesDistinctServiceAndAccountFromOAuth() {
    let oauth = KeychainTokenStore.gitHubOAuthStore()
    let pat = KeychainTokenStore.gitHubPATStore()

    XCTAssertEqual(oauth.service, "StargazerBar.GitHubOAuth")
    XCTAssertEqual(oauth.account, "github-oauth")
    XCTAssertEqual(pat.service, "StargazerBar.GitHubPAT")
    XCTAssertEqual(pat.account, "github-pat")
    // The (service, account) pair is the Keychain primary key; both must differ
    // so a PAT can never be read back as an OAuth token or vice versa.
    XCTAssertNotEqual(oauth.service, pat.service)
    XCTAssertNotEqual(oauth.account, pat.account)
}

func testPATStoreReadsThroughInjectedCopyMatching() {
    var capturedService: String?
    let store = KeychainTokenStore(service: KeychainTokenStore.gitHubPATService, account: "github-pat") { query, _ in
        let dict = query as! [String: Any]
        capturedService = dict[kSecAttrService as String] as? String
        return errSecItemNotFound
    }

    XCTAssertNil(try store.loadToken(allowUserInteraction: false))
    XCTAssertEqual(capturedService, "StargazerBar.GitHubPAT")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testPATStoreUsesDistinctServiceAndAccountFromOAuth 2>&1 | tail -5
```
Expected: **BUILD FAILURE**, `type 'KeychainTokenStore' has no member 'gitHubPATStore'`.

- [ ] **Step 3: Write minimal implementation**

In `GHMenuStars/Persistence/KeychainTokenStore.swift`, replace lines 8-25 with:

```swift
    static let gitHubOAuthService = "StargazerBar.GitHubOAuth"
    static let legacyGitHubOAuthService = "GHMenuStars.GitHubOAuth"
    static let gitHubPATService = "StargazerBar.GitHubPAT"

    let service: String
    // Must precede `copyMatching`: the memberwise init keeps `copyMatching`
    // last so ServiceLogicTests' trailing-closure construction still binds.
    // Must be `var` with a default, not `let` — a `let` with an initial value
    // is excluded from the synthesized memberwise init.
    var account: String = "github-oauth"
    var copyMatching: CopyMatching = SecItemCopyMatching

    static func gitHubOAuthStore() -> KeychainTokenStore {
        KeychainTokenStore(service: gitHubOAuthService)
    }

    static func gitHubPATStore() -> KeychainTokenStore {
        KeychainTokenStore(service: gitHubPATService, account: "github-pat")
    }

    static func loadGitHubOAuthToken() -> String? {
        try? gitHubOAuthStore().loadToken(allowUserInteraction: false)
    }

    static func hasGitHubOAuthToken() -> Bool {
        loadGitHubOAuthToken() != nil
    }

    static func loadGitHubPAT() -> String? {
        try? gitHubPATStore().loadToken(allowUserInteraction: false)
    }

    static func hasGitHubPAT() -> Bool {
        loadGitHubPAT() != nil
    }
```

Then delete the now-duplicated `private let account = "github-oauth"` line.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**. The whole `ServiceLogicTests` suite runs here, not just the new tests, because the `account` reordering could break the existing trailing-closure construction at `:1023` — that test passing is the real signal.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Persistence/KeychainTokenStore.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(keychain): add fine-grained PAT store alongside OAuth token

Parameterizes account (var with default, declared before copyMatching so
the memberwise init keeps copyMatching last for trailing-closure call
sites). The (service, account) pair is the Keychain primary key, so the
PAT can never be read back as an OAuth token."
```

---

### Task 2: Hidden flag

**Files:**
- Modify: `GHMenuStars/Persistence/SettingsStore.swift:123-175`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettings.enablePrivateRepos: Bool` (default `false`).

This gates the PAT Settings section so main stays releasable while phase 1 lands. Phase 2 flips the default.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/ServiceLogicTests.swift`:

```swift
func testPrivateReposFlagDefaultsOffAndSurvivesLegacyDecode() throws {
    // Fresh settings: flag must be off, or a hotfix cut from main exposes the
    // PAT section before the menu bar has any private-repo answer.
    XCTAssertFalse(AppSettings().enablePrivateRepos)

    // Settings JSON written by a build that predates the flag must decode,
    // not throw — SettingsStore falls back to defaults on any decode error,
    // which would silently reset every setting the user has.
    // AppSettings.init(from:) hard-decodes these (SettingsStore.swift:158-167) —
    // omit any and the decode throws keyNotFound before reaching our flag.
    let legacy = Data("""
    {"refreshInterval":"tenMinutes","hideDockIcon":true,"notifyOnStarIncrease":true,
     "playSoundOnStarIncrease":false,"animateOnStarIncrease":true,
     "gitHubOAuthClientID":"","menuBarDisplayMode":"selectedRepoStars"}
    """.utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
    XCTAssertFalse(decoded.enablePrivateRepos)

    var enabled = AppSettings()
    enabled.enablePrivateRepos = true
    let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(enabled))
    XCTAssertTrue(round.enablePrivateRepos)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testPrivateReposFlagDefaultsOffAndSurvivesLegacyDecode 2>&1 | tail -5
```
Expected: **BUILD FAILURE**, `value of type 'AppSettings' has no member 'enablePrivateRepos'`.

- [ ] **Step 3: Write minimal implementation**

In `GHMenuStars/Persistence/SettingsStore.swift`, add the stored property to `AppSettings` after `maintainerRadarActivityWindow` (line 136):

```swift
    /// Phase 1 ships internally: the PAT Settings section stays hidden so a
    /// hotfix cut from main can't expose private-repo tracking before the menu
    /// bar has any private-repo answer (phase 3). Flipped on in phase 2.
    var enablePrivateRepos: Bool = false
```

Add to `CodingKeys`:

```swift
        case enablePrivateRepos
```

Add to `init(from:)`, alongside the other `decodeIfPresent` calls:

```swift
        enablePrivateRepos = try container.decodeIfPresent(Bool.self, forKey: .enablePrivateRepos) ?? false
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Persistence/SettingsStore.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(settings): add enablePrivateRepos flag, default off

Gates the phase 1 PAT section so main stays releasable for hotfixes
during launch prep. Flipped on in phase 2."
```

---

### Task 3: `isPrivate` through model and store

**Files:**
- Modify: `GHMenuStars/Models/TrackedRepo.swift:285-427`
- Modify: `GHMenuStars/Models/RepoSnapshot.swift:3-15`
- Modify: `GHMenuStars/Persistence/TrackedRepoStore.swift:42-70` and `:101-137`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `TrackedRepo.isPrivate: Bool` (init param `isPrivate: Bool = false`, positioned after `source`)
  - `RepoSnapshot.isPrivate: Bool` (default `false`)
  - `TrackedRepoStore.apply(snapshot:to:)` resets `etagRepo`/`etagReleases` to `nil` when `snapshot.isPrivate != repo.isPrivate`

Stored repos predate private support, so `false` is the correct decode default. `upsertTrackedRepo` copies fields member-by-member — a new field not added there is **silently dropped** on re-add.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/ServiceLogicTests.swift`:

```swift
func testTrackedRepoDecodesLegacyJSONWithoutIsPrivate() throws {
    let legacy = Data("""
    {"id":"\(UUID().uuidString)","owner":"o","name":"n","displayName":"o/n",
     "source":"manual","starSound":"glass","isMuted":false,"trendPoints":[],
     "starAskPromptStatus":"notShown"}
    """.utf8)
    let repo = try JSONDecoder().decode(TrackedRepo.self, from: legacy)
    XCTAssertFalse(repo.isPrivate)
}

@MainActor
func testApplySnapshotRoundTripsIsPrivateAndResetsETagsOnFlip() {
    let store = TrackedRepoStore(defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!, legacyDefaults: nil)
    let repo = TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: false,
                           etagRepo: "etag-public", etagReleases: "etag-releases-public")
    try? store.upsertTrackedRepo(repo)

    // A flip means the stored ETags were minted under a different identity.
    // Serving a 304 against them would return the wrong body.
    let flipped = RepoSnapshot(stars: 0, releaseDownloads: 0, forks: 0,
                               checkedAt: Date(), repoETag: nil, releasesETag: nil,
                               isPrivate: true)
    _ = store.apply(snapshot: flipped, to: repo.id)

    let stored = store.repo(id: repo.id)
    XCTAssertEqual(stored?.isPrivate, true)
    XCTAssertNil(stored?.etagRepo)
    XCTAssertNil(stored?.etagReleases)
}

@MainActor
func testUpsertPreservesIsPrivateOnReAdd() {
    let store = TrackedRepoStore(defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!, legacyDefaults: nil)
    let repo = TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: true)
    try? store.upsertTrackedRepo(repo)
    // Re-adding the same repo must not silently drop isPrivate: upsert copies
    // fields member-by-member, so an unlisted field is lost.
    try? store.upsertTrackedRepo(TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: true))
    XCTAssertEqual(store.repo(id: store.trackedRepos.first?.id)?.isPrivate, true)
}
```

**`legacyDefaults: nil` is mandatory, not decoration — for `SettingsStore` too.** Both `TrackedRepoStore.init` (`:23`) and `SettingsStore.init` (`SettingsStore.swift:193`) default `legacyDefaults` to a **real** suite — `UserDefaults(suiteName: "com.jazzyalex.GHMenuStars")` (`TrackedRepoStore.swift:23`) — so omitting it makes the test read the developer's actual stored repos. Every existing store test passes `legacyDefaults: nil` for this reason (e.g. `ServiceLogicTests.swift:10`). The per-test `UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!` fixture is the established pattern; there is no `emptyDefaults()` helper.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testTrackedRepoDecodesLegacyJSONWithoutIsPrivate 2>&1 | tail -5
```
Expected: **BUILD FAILURE**, `value of type 'TrackedRepo' has no member 'isPrivate'`.

- [ ] **Step 3: Write minimal implementation**

`GHMenuStars/Models/TrackedRepo.swift` — add the stored property after `source` (line 290):

```swift
    var isPrivate: Bool
```

Add to `CodingKeys` after `case source`:

```swift
        case isPrivate
```

Add to the memberwise `init`, after `source: RepoSource,`:

```swift
        isPrivate: Bool = false,
```

and in the body after `self.source = source`:

```swift
        self.isPrivate = isPrivate
```

Add to `init(from:)` after the `source` decode:

```swift
        // Stored repos predate private support; false is the correct default.
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
```

`GHMenuStars/Models/RepoSnapshot.swift` — add:

```swift
    var isPrivate: Bool = false
```

`GHMenuStars/Persistence/TrackedRepoStore.swift` — in `upsertTrackedRepo`, after `existing.source = repo.source`:

```swift
            existing.isPrivate = repo.isPrivate
```

In `apply(snapshot:to:)`, after `var repo = trackedRepos[index]` and before the existing ETag assignments:

```swift
        // A visibility flip invalidates ETags: they were minted under a
        // different auth identity, so a 304 against them would serve a body
        // the other identity could see.
        let didFlipVisibility = repo.isPrivate != snapshot.isPrivate
        repo.isPrivate = snapshot.isPrivate
```

Then replace the two existing ETag lines (`:117-118`) with:

```swift
        repo.etagRepo = didFlipVisibility ? nil : (snapshot.repoETag ?? repo.etagRepo)
        repo.etagReleases = didFlipVisibility ? nil : (snapshot.releasesETag ?? repo.etagReleases)
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**, including the pre-existing `testTrackedReposMigrateFromLegacyBundleDefaults` at `ServiceLogicTests.swift:472`.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Models/TrackedRepo.swift GHMenuStars/Models/RepoSnapshot.swift GHMenuStars/Persistence/TrackedRepoStore.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(model): persist isPrivate on TrackedRepo

Decodes false for repos stored before private support, so migration is
free. Carried through both upsert (which copies member-by-member) and
apply. A visibility flip clears ETags, which were minted under a
different auth identity."
```

---

### Task 4: `optionalAuthToken` on the three GitHubClient entry points

**Files:**
- Modify: `GHMenuStars/GitHub/GitHubClient.swift:212-226` (`fetchRepo`, `fetchReleases`)
- Modify: `GHMenuStars/GitHub/GitHubClient.swift:334-342` (`fetchMaintainerRadar`)
- Test: `GHMenuStarsTests/GitHubModelTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `GitHubClient.fetchRepo(owner:name:etag:optionalAuthToken:)` — `optionalAuthToken: String? = nil`
  - `GitHubClient.fetchReleases(owner:name:etag:optionalAuthToken:)` — `optionalAuthToken: String? = nil`
  - `GitHubClient.fetchMaintainerRadar(owner:name:activityWindow:releaseAnchor:now:optionalAuthToken:)` — `optionalAuthToken: String? = nil`

**`fetchMaintainerRadar` is the critical one.** Its private helpers already thread `optionalAuthToken`, but the public entry point derives the token itself at `:342` (`let optionalAuthToken = optionalTokenProvider()`), and `AppDelegate.swift:9-16` wires that provider to the **OAuth token only**. Without this parameter, a private repo's 4 search calls, commit count and workflow check all go out on a token that cannot see the repo, 404, and get swallowed into `nil` by the `optional*` wrappers — **blank radar rows with no error**. That is the entire feature failing silently.

The `nil` defaults keep every existing call site and all ~15 `GitHubClient` constructions in `GitHubModelTests` compiling and behaving identically.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/GitHubModelTests.swift`, mirroring `testMaintainerRadarUsesOptionalTokenForPublicEndpoints` at `:199`.

`activityWindow: .off` is deliberate and load-bearing: it makes `activityStart` nil, so `optionalActivityCount` returns without issuing the `created:>=`-stamped requests whose paths embed `Date()` and therefore cannot be pre-keyed into `MockURLProtocol.responses`. That leaves exactly 3 deterministic paths. Do not "improve" this to `.oneDay`.

```swift
func testMaintainerRadarPrefersSuppliedTokenOverAmbientProvider() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    var ambientCallCount = 0
    let client = GitHubClient(session: session, optionalTokenProvider: {
        ambientCallCount += 1
        return "ambient-oauth"
    })

    MockURLProtocol.responses = [
        "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
            data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
        ),
        "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
            data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
        ),
        "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
            data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
        )
    ]

    _ = await client.fetchMaintainerRadar(
        owner: "owner", name: "repo", activityWindow: .off, optionalAuthToken: "pat-token"
    )

    XCTAssertEqual(MockURLProtocol.requestedAuthorizations.count, 3)
    // The whole feature: any radar call carrying the ambient token 404s on a
    // private repo and the optional* wrappers turn it into a blank row, silently.
    XCTAssertTrue(MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer pat-token" },
                  "radar used the ambient token: \(MockURLProtocol.requestedAuthorizations)")
    XCTAssertEqual(ambientCallCount, 0, "a supplied token must short-circuit the ambient provider")
}

func testMaintainerRadarFallsBackToAmbientWhenNoTokenSupplied() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = GitHubClient(session: session, optionalTokenProvider: { "ambient-oauth" })

    MockURLProtocol.responses = [
        "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
            data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
        ),
        "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
            data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
        ),
        "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
            data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
        )
    ]

    _ = await client.fetchMaintainerRadar(owner: "owner", name: "repo", activityWindow: .off)

    // Public repos must behave exactly as before this change.
    XCTAssertTrue(MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer ambient-oauth" })
}
```

Call `MockURLProtocol.reset()` in `setUp` if the existing suite does not already.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubModelTests/testMaintainerRadarPrefersSuppliedTokenOverAmbientProvider 2>&1 | tail -5
```
Expected: **BUILD FAILURE**, `extra argument 'optionalAuthToken' in call`.

- [ ] **Step 3: Write minimal implementation**

`GHMenuStars/GitHub/GitHubClient.swift` — replace `fetchRepo` and `fetchReleases` (lines 212-226):

```swift
    func fetchRepo(
        owner: String,
        name: String,
        etag: String?,
        optionalAuthToken: String? = nil
    ) async throws -> GitHubHTTPResult<GitHubRepoResponse> {
        try await request(
            path: "/repos/\(owner)/\(name)",
            etag: etag,
            requiresAuth: false,
            optionalAuthToken: optionalAuthToken
        )
    }

    func fetchReleases(
        owner: String,
        name: String,
        etag: String?,
        optionalAuthToken: String? = nil
    ) async throws -> GitHubHTTPResult<[GitHubRelease]> {
        try await request(
            path: "/repos/\(owner)/\(name)/releases?per_page=100",
            etag: etag,
            requiresAuth: false,
            optionalAuthToken: optionalAuthToken
        )
    }
```

`request()` already resolves `optionalAuthToken ?? optionalTokenProvider()` at `:541`, so a `nil` argument preserves today's behaviour exactly.

Then change `fetchMaintainerRadar`'s signature (line 334) to add a final parameter:

```swift
    func fetchMaintainerRadar(
        owner: String,
        name: String,
        activityWindow: MaintainerRadarActivityWindow,
        releaseAnchor: Date? = nil,
        now: Date = Date(),
        optionalAuthToken: String? = nil
    ) async -> RepoMaintainerRadar {
```

and replace line 342:

```swift
        let optionalAuthToken = optionalTokenProvider()
```

with:

```swift
        // A supplied token wins: for a private repo this is the PAT, and the
        // ambient provider only ever holds the OAuth token, which cannot see it.
        let optionalAuthToken = optionalAuthToken ?? optionalTokenProvider()
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubModelTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**, including `testPublicRepoFetchDoesNotReadToken` (`:153`) and `testPublicRepoFetchUsesOptionalTokenWhenAvailable` (`:176`) **unmodified** — they are the regression guards for the byte-identical-public-behaviour constraint.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/GitHub/GitHubClient.swift GHMenuStarsTests/GitHubModelTests.swift
git commit -m "feat(github): allow a per-call auth token on repo, releases, radar

fetchMaintainerRadar previously derived its token from the ambient
provider, which holds only the OAuth token. A private repo's radar would
have 404'd into the optional* wrappers and rendered blank rows with no
error. Defaults are nil, so public behaviour is unchanged."
```

---

### Task 5: GitHubRepoAccess — resolution rule

**Files:**
- Create: `GHMenuStars/GitHub/GitHubRepoAccess.swift`
- Test: `GHMenuStarsTests/GitHubRepoAccessTests.swift` (create)

**Interfaces:**
- Consumes: `KeychainTokenStore.loadGitHubPAT()`, `KeychainTokenStore.loadGitHubOAuthToken()` (Task 1); `GitHubClient.fetchRepo(owner:name:etag:optionalAuthToken:)` (Task 4).
- Produces:
  - `@MainActor final class GitHubRepoAccess`
  - `GitHubRepoAccess.Outcome` — `.fetched(result: GitHubHTTPResult<GitHubRepoResponse>, isPrivate: Bool, token: String?)` | `.notModified(token: String?)`
  - `init(client:patProvider:ambientProvider:)`
  - `func fetchRepo(owner: String, name: String, etag: String?, knownPrivate: Bool, repoID: UUID?) async throws -> Outcome`
  - `func resetTokenState()`
  - `var isPATDead: Bool` (read-only; Task 14 renders the revoked-token message from it)

**Why `Outcome` is an enum, not a struct:** `request()` *throws* `GitHubError.notModified` on 304 (`GitHubClient.swift:570-571`) and never produces a `GitHubHTTPResult`. A struct with a non-optional `result` cannot be constructed on the 304 path — which is the **normal steady state** of every poll (`RepoPollingService.swift:136-137, 143`).

**Why `@MainActor final class`, not the struct in the spec sketch:** the latches (Tasks 6-7) are mutable state that must persist across calls. `RepoPollingService` is already `@MainActor final class` (`:28-29`) and `refresh()` is MainActor-isolated, so MainActor isolation introduces no new concurrency model and no actor hops. `await` on the network call releases the MainActor as normal.

- [ ] **Step 1: Make the existing MockURLProtocol shareable**

`MockURLProtocol` already exists at `GitHubModelTests.swift:541` but is **`private`**, so a new test file cannot see it. Do not write a second stub — move it to a shared support file and extend it.

Create `GHMenuStarsTests/Support/MockURLProtocol.swift` by **moving** the class from `GitHubModelTests.swift:541` verbatim (deleting it there), dropping the `private` keyword, and adding a handler hook:

```swift
import Foundation

final class MockURLProtocol: URLProtocol {
    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var data: Data
    }

    /// Takes precedence over `responses` when set. Needed because `responses` is
    /// keyed by path, so it cannot answer the same path differently on
    /// successive calls — which every retry test requires (404 then 200 on
    /// /repos/o/n).
    static var handler: ((URLRequest) -> Response?)?

    static var responses: [String: Response] = [:]
    static var requestedPaths: [String] = []
    static var requestedAccepts: [String] = []
    static var requestedAuthorizations: [String?] = []
    private static let lock = NSLock()

    // ... canInit / canonicalRequest / pathAndQuery unchanged from the original ...

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let key = Self.pathAndQuery(for: url)
        Self.lock.lock()
        Self.requestedPaths.append(key)
        Self.requestedAccepts.append(request.value(forHTTPHeaderField: "Accept") ?? "")
        Self.requestedAuthorizations.append(request.value(forHTTPHeaderField: "Authorization"))
        Self.lock.unlock()

        let resolved = Self.handler?(request) ?? Self.responses[key]
        guard let response = resolved,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        responses = [:]
        requestedPaths = []
        requestedAccepts = []
        requestedAuthorizations = []
    }
}
```

The `handler` hook and the `reset()` line for it are the only behavioural additions; when `handler` is nil the class behaves exactly as before, so every existing `GitHubModelTests` test is unaffected.

Verify the move first:

```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubModelTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** — the move must not disturb the existing suite.

- [ ] **Step 2: Write the failing test**

Create `GHMenuStarsTests/GitHubRepoAccessTests.swift`:

```swift
import XCTest
@testable import GHMenuStars

@MainActor
final class GitHubRepoAccessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    /// Builds a real GitHubClient over a stubbed URLSession, so the true request
    /// path is exercised rather than a mock of it.
    private func makeAccess(pat: String?, ambient: String?) -> GitHubRepoAccess {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return GitHubRepoAccess(
            client: GitHubClient(session: URLSession(configuration: config)),
            patProvider: { pat },
            ambientProvider: { ambient }
        )
    }

    private func repoBody(isPrivate: Bool) -> Data {
        Data(#"{"full_name":"o/n","stargazers_count":0,"forks_count":0,"private":\#(isPrivate)}"#.utf8)
    }

    private var tokens: [String] {
        MockURLProtocol.requestedAuthorizations.map { $0 ?? "<none>" }
    }

    func testPublicRepoUsesAmbientTokenAndReportsNotPrivate() async throws {
        MockURLProtocol.responses = [
            "/repos/o/n": .init(data: repoBody(isPrivate: false))
        ]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())

        guard case .fetched(_, let isPrivate, let token) = outcome else { return XCTFail("expected .fetched") }
        XCTAssertFalse(isPrivate)
        XCTAssertEqual(token, "oauth")
        XCTAssertEqual(tokens, ["Bearer oauth"], "a known-public repo must not spend a PAT call")
    }

    func testUnknownPrivateRepo404sOnAmbientThenSucceedsOnPATAndLearnsItIsPrivate() async throws {
        var calls = 0
        MockURLProtocol.handler = { [self] _ in
            calls += 1
            // GitHub 404s (not 403s) for a private repo you can't see, by design.
            return calls == 1
                ? .init(statusCode: 404, data: Data("{}".utf8))
                : .init(data: repoBody(isPrivate: true))
        }
        let access = makeAccess(pat: "pat", ambient: "oauth")

        let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())

        guard case .fetched(_, let isPrivate, let token) = outcome else { return XCTFail("expected .fetched") }
        XCTAssertTrue(isPrivate, "isPrivate must come from the response body, not from what was stored")
        XCTAssertEqual(token, "pat")
        XCTAssertEqual(tokens, ["Bearer oauth", "Bearer pat"])
    }

    func testKnownPrivateRepoTriesPATFirst() async throws {
        MockURLProtocol.responses = ["/repos/o/n": .init(data: repoBody(isPrivate: true))]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())

        XCTAssertEqual(tokens, ["Bearer pat"], "a known-private repo must not waste a doomed ambient call")
    }

    func testPATOnlyUserUsesPATForPublicReposRatherThanAnonymous() async throws {
        // No OAuth token: anonymous would put public repos on the 60/hr per-IP
        // bucket, and the global rate-limit gate would then starve private repos.
        MockURLProtocol.responses = ["/repos/o/n": .init(data: repoBody(isPrivate: false))]
        let access = makeAccess(pat: "pat", ambient: nil)

        _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())

        XCTAssertEqual(tokens, ["Bearer pat"])
    }

    func testNotModifiedCarriesTheTokenAndDoesNotThrow() async throws {
        MockURLProtocol.responses = ["/repos/o/n": .init(statusCode: 304, data: Data())]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: "e", knownPrivate: true, repoID: UUID())

        guard case .notModified(let token) = outcome else { return XCTFail("expected .notModified") }
        // 304 is the normal poll steady state; the releases and radar calls that
        // follow still need the identity that just worked.
        XCTAssertEqual(token, "pat")
    }

    func testRateLimited403PropagatesWithoutRetry() async {
        MockURLProtocol.responses = [
            "/repos/o/n": .init(
                statusCode: 403,
                headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "9999999999"],
                data: Data("{}".utf8)
            )
        ]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        do {
            _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())
            XCTFail("expected rateLimited to propagate")
        } catch GitHubError.rateLimited {
            // Retrying under rate limit only deepens the hole.
            XCTAssertEqual(tokens.count, 1)
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func testBothIdentities404Throws() async {
        MockURLProtocol.responses = ["/repos/o/n": .init(statusCode: 404, data: Data("{}".utf8))]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        do {
            _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())
            XCTFail("expected notFoundOrPrivate")
        } catch GitHubError.notFoundOrPrivate {
            XCTAssertEqual(tokens, ["Bearer oauth", "Bearer pat"])
        } catch {
            XCTFail("expected notFoundOrPrivate, got \(error)")
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubRepoAccessTests 2>&1 | tail -5
```
Expected: **BUILD FAILURE**, `cannot find 'GitHubRepoAccess' in scope`.

**Add every new file to the Xcode target.** `project.pbxproj` is `objectVersion = 56` with explicit `PBXFileReference` entries and **no** filesystem-synchronized groups, so a new file on disk is invisible to the build until it is registered. This applies to `GitHubRepoAccess.swift`, `GitHubRepoAccessTests.swift`, `Support/MockURLProtocol.swift` (Task 5) and `GitHubAuthSettingsView.swift` (Task 14). It is not conditional — it will fail.

- [ ] **Step 4: Write minimal implementation**

Create `GHMenuStars/GitHub/GitHubRepoAccess.swift`:

```swift
import Foundation

/// Decides which token each repo's requests carry.
///
/// GitHub returns 404 — not 403 — for a private repo you cannot see, by design,
/// so that private repos aren't enumerable. A repo's privacy is therefore only
/// knowable from a *successful* fetch, which makes a try-then-retry ladder
/// unavoidable: there is no way to ask "is this private?" before having already
/// authenticated correctly for it.
@MainActor
final class GitHubRepoAccess {
    enum Outcome {
        /// 2xx. `isPrivate` is authoritative — read from the response body.
        case fetched(result: GitHubHTTPResult<GitHubRepoResponse>, isPrivate: Bool, token: String?)
        /// 304. No body, so `isPrivate` cannot be refreshed and the caller keeps
        /// the stored value. Carries the token the 304'd request used so the
        /// repo's releases and radar calls reuse the identity that just worked.
        case notModified(token: String?)
    }

    private let client: GitHubClient
    private let patProvider: () -> String?
    private let ambientProvider: () -> String?

    /// A revoked or expired PAT is dead for every repo, not one. In-memory only:
    /// never persist auth state that can be cheaply re-derived.
    private var patIsDead = false
    /// Repos no identity can see — deleted upstream, or a typo tracked while
    /// public. Without this they burn two calls per poll forever.
    private var doubleFailedRepoIDs: Set<UUID> = []

    init(
        client: GitHubClient,
        patProvider: @escaping () -> String? = { KeychainTokenStore.loadGitHubPAT() },
        ambientProvider: @escaping () -> String? = { KeychainTokenStore.loadGitHubOAuthToken() }
    ) {
        self.client = client
        self.patProvider = patProvider
        self.ambientProvider = ambientProvider
    }

    /// Clears both latches. Call when the PAT is saved or removed.
    func resetTokenState() {
        patIsDead = false
        doubleFailedRepoIDs.removeAll()
    }

    /// True once a PAT attempt has come back 401. Settings renders the
    /// revoked-token message from this: after the latch the ambient fallback
    /// usually 404s, which would otherwise surface as a generic "not found"
    /// and send the user hunting for the wrong problem.
    var isPATDead: Bool { patIsDead }

    private var livePAT: String? { patIsDead ? nil : patProvider() }

    func fetchRepo(
        owner: String,
        name: String,
        etag: String?,
        knownPrivate: Bool,
        repoID: UUID? = nil
    ) async throws -> Outcome {
        let pat = livePAT
        let ambient = ambientProvider()
        // Prefer the PAT when we know it's needed, or when there is no ambient
        // token to protect: a PAT-only user would otherwise poll public repos
        // anonymously on the 60/hr per-IP bucket, and the global rate-limit gate
        // would then starve the private repos the PAT could still serve.
        let preferPAT = pat != nil && (knownPrivate || ambient == nil)
        let firstToken = preferPAT ? pat : ambient

        do {
            return try await attempt(owner: owner, name: name, etag: etag, token: firstToken)
        } catch GitHubError.unauthorized where preferPAT {
            // Fires regardless of knownPrivate: a repo that flipped private->public
            // while the PAT was revoked must still recover, and a revoked PAT
            // answers 401, not 404, so the 404 ladder alone would strand it.
            patIsDead = true
            return try await attempt(owner: owner, name: name, etag: etag, token: ambient)
        } catch GitHubError.notFoundOrPrivate where !preferPAT && pat != nil && !isDoubleFailed(repoID) {
            do {
                return try await attempt(owner: owner, name: name, etag: etag, token: pat)
            } catch GitHubError.notFoundOrPrivate {
                if let repoID { doubleFailedRepoIDs.insert(repoID) }
                throw GitHubError.notFoundOrPrivate
            }
        }
        // GitHubError.rateLimited matches no catch clause and propagates
        // untouched: retrying under rate limit only deepens the hole.
    }

    private func isDoubleFailed(_ repoID: UUID?) -> Bool {
        guard let repoID else { return false }
        return doubleFailedRepoIDs.contains(repoID)
    }

    private func attempt(
        owner: String,
        name: String,
        etag: String?,
        token: String?
    ) async throws -> Outcome {
        do {
            let result = try await client.fetchRepo(
                owner: owner, name: name, etag: etag, optionalAuthToken: token
            )
            return .fetched(result: result, isPrivate: result.value.private, token: token)
        } catch GitHubError.notModified {
            return .notModified(token: token)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubRepoAccessTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 6: Commit**

```bash
git add GHMenuStars/GitHub/GitHubRepoAccess.swift GHMenuStarsTests/GitHubRepoAccessTests.swift GHMenuStars.xcodeproj
git commit -m "feat(github): add GitHubRepoAccess token resolution seam

GitHub 404s identically for missing and invisible repos, so privacy is
only knowable from a successful fetch. Tries ambient first, retries once
with the PAT, and always reads isPrivate from the response body. 304
returns .notModified carrying the winning token; rate-limited 403s
propagate without retry."
```

---

### Task 6: PAT-dead latch

**Files:**
- Modify: `GHMenuStars/GitHub/GitHubRepoAccess.swift` (already written in Task 5 — this task tests it)
- Test: `GHMenuStarsTests/GitHubRepoAccessTests.swift` (append)

**Interfaces:**
- Consumes: `GitHubRepoAccess` (Task 5).
- Produces: no new API. Verifies `patIsDead` behaviour and `resetTokenState()`.

The latch keeps the recovery path at **one** call per poll instead of two, bounded at one wasted 401 per app launch since 401 is deterministic, not transient.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/GitHubRepoAccessTests.swift`:

```swift
func testRevokedPATLatchesDeadAndFallsBackToAmbient() async throws {
    var seen: [String?] = []
    var calls = 0
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.handler = { request in
        seen.append(request.value(forHTTPHeaderField: "Authorization"))
        calls += 1
        // PAT is revoked -> 401. Repo has since flipped public, so the ambient
        // token can see it.
        if calls == 1 { return .init(statusCode: 401, data: Data("{}".utf8)) }
        return .init(data: Data(#"{"full_name":"o/n","stargazers_count":3,"forks_count":0,"private":false}"#.utf8))
    }
    let access = GitHubRepoAccess(
        client: GitHubClient(session: URLSession(configuration: config)),
        patProvider: { "revoked-pat" },
        ambientProvider: { "oauth" }
    )

    // A repo stored as private, whose PAT is dead, that flipped public.
    let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())
    guard case .fetched(_, let isPrivate, let token) = outcome else { return XCTFail("expected .fetched") }
    XCTAssertFalse(isPrivate)
    XCTAssertEqual(token, "oauth")
    XCTAssertEqual(seen, ["Bearer revoked-pat", "Bearer oauth"])

    // Next poll must NOT try the dead PAT again: one call, not two.
    seen.removeAll()
    _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())
    XCTAssertEqual(seen, ["Bearer oauth"], "latched PAT must not be retried every poll")
}

func testResetTokenStateRevivesTheLatchedPAT() async throws {
    var seen: [String?] = []
    var failNextWith401 = true
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.handler = { request in
        seen.append(request.value(forHTTPHeaderField: "Authorization"))
        if failNextWith401 {
            failNextWith401 = false
            return .init(statusCode: 401, data: Data("{}".utf8))
        }
        return .init(data: Data(#"{"full_name":"o/n","stargazers_count":0,"forks_count":0,"private":true}"#.utf8))
    }
    let access = GitHubRepoAccess(
        client: GitHubClient(session: URLSession(configuration: config)),
        patProvider: { "pat" },
        ambientProvider: { "oauth" }
    )

    _ = try? await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())

    // The user pasted a working token; the latch must clear or they'd have to relaunch.
    access.resetTokenState()
    seen.removeAll()
    _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())
    XCTAssertEqual(seen.first, "Bearer pat")
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubRepoAccessTests/testRevokedPATLatchesDeadAndFallsBackToAmbient 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** — Task 5's implementation already contains the latch. If it **fails**, the Task 5 implementation is wrong; fix `GitHubRepoAccess.swift` rather than weakening the test.

- [ ] **Step 3: Fix only if Step 2 failed**

If `testRevokedPATLatchesDeadAndFallsBackToAmbient` failed, the likely cause is the `where preferPAT` clause on the `unauthorized` catch not firing. Verify `preferPAT` is `true` when `knownPrivate` is `true` and a PAT exists, and that `patIsDead = true` is set **before** the ambient retry.

- [ ] **Step 4: Run the whole suite**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubRepoAccessTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStarsTests/GitHubRepoAccessTests.swift
git commit -m "test(github): cover PAT-dead latch and its reset

A revoked PAT answers 401, not 404, so without the 401 clause a repo that
flipped private->public while the PAT was dead would be stranded forever."
```

---

### Task 7: Double-404 latch

**Files:**
- Test: `GHMenuStarsTests/GitHubRepoAccessTests.swift` (append)

**Interfaces:**
- Consumes: `GitHubRepoAccess` (Task 5).
- Produces: no new API. Verifies `doubleFailedRepoIDs` behaviour.

Distinct from Task 6: that latch is about a dead *token*, this one about a dead *repo*. A tracked repo deleted upstream would otherwise 404 on both identities every poll — ~288 wasted calls/day at the 10-minute default.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/GitHubRepoAccessTests.swift`:

```swift
func testMissingRepoStopsCostingTwoCallsPerPoll() async {
    var seen: [String?] = []
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.handler = { request in
        seen.append(request.value(forHTTPHeaderField: "Authorization"))
        return .init(statusCode: 404, data: Data("{}".utf8))   // deleted upstream, or a typo
    }
    let access = GitHubRepoAccess(
        client: GitHubClient(session: URLSession(configuration: config)),
        patProvider: { "pat" },
        ambientProvider: { "oauth" }
    )
    let repoID = UUID()

    // First poll pays for the full ladder to learn the repo is unreachable.
    do { _ = try await access.fetchRepo(owner: "o", name: "gone", etag: nil, knownPrivate: false, repoID: repoID) }
    catch {}
    XCTAssertEqual(seen, ["Bearer oauth", "Bearer pat"])

    // Every poll after that costs one call, as it did before PATs existed.
    seen.removeAll()
    do { _ = try await access.fetchRepo(owner: "o", name: "gone", etag: nil, knownPrivate: false, repoID: repoID) }
    catch {}
    XCTAssertEqual(seen, ["Bearer oauth"], "missing repo must not burn a PAT retry every poll")

    // A new PAT may well grant access, so the latch must clear with the token.
    access.resetTokenState()
    seen.removeAll()
    do { _ = try await access.fetchRepo(owner: "o", name: "gone", etag: nil, knownPrivate: false, repoID: repoID) }
    catch {}
    XCTAssertEqual(seen, ["Bearer oauth", "Bearer pat"])
}
```

- [ ] **Step 2: Run test to verify it passes**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubRepoAccessTests/testMissingRepoStopsCostingTwoCallsPerPoll 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** — Task 5 already implements the latch. If it fails, fix `GitHubRepoAccess.swift`.

- [ ] **Step 3: Run the whole suite**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubRepoAccessTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 4: Commit**

```bash
git add GHMenuStarsTests/GitHubRepoAccessTests.swift
git commit -m "test(github): cover the double-404 repo latch

A repo deleted upstream would otherwise burn a PAT retry on every poll
forever. Clears with the PAT, which may grant access the old one lacked."
```

---

### Task 8: Wire GitHubRepoAccess through AppDelegate and PreferencesWindow

**Files:**
- Modify: `GHMenuStars/AppDelegate.swift:5-24`
- Modify: `GHMenuStars/PreferencesWindow.swift:45-63`
- Modify: `GHMenuStars/Services/RepoPollingService.swift:28-45` (init only)
- Modify: `GHMenuStars/SettingsView.swift` (init/property only)

**Interfaces:**
- Consumes: `GitHubRepoAccess.init(client:patProvider:ambientProvider:)` (Task 5).
- Produces:
  - `RepoPollingService.init(repoStore:settingsStore:gitHubClient:repoAccess:notificationService:soundService:animationCoordinator:)`
  - `PreferencesWindow.show(repoStore:settingsStore:gitHubClient:repoAccess:updaterController:)`
  - `SettingsView` gains a `let repoAccess: GitHubRepoAccess` property

Pure plumbing: no behaviour changes. The seam is useless until it reaches its call sites, and `GitHubRepoAccess` must be a **single shared instance** — two instances would each keep their own latches, so a PAT revoked in one would still be retried by the other.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/GitHubRepoAccessTests.swift`:

```swift
func testPollingServiceAcceptsInjectedRepoAccess() async {
    // Compile-level guard: the seam must actually reach the poller. If this
    // stops compiling, the wiring regressed.
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.handler = { _ in .init(statusCode: 404, data: Data("{}".utf8)) }
    let client = GitHubClient(session: URLSession(configuration: config))
    let access = GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { nil })
    let service = RepoPollingService(
        repoStore: TrackedRepoStore(defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!, legacyDefaults: nil),
        settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!, legacyDefaults: nil),
        gitHubClient: client,
        repoAccess: access,
        notificationService: NotificationService(),
        soundService: SoundService(),
        animationCoordinator: AnimationCoordinator()
    )
    XCTAssertNotNil(service)
}
```

Mirror `AppDelegate.swift:17-24` for the `NotificationService`/`SoundService`/`AnimationCoordinator` construction. Pass `legacyDefaults: nil` (see Task 3) so the test cannot touch the real `com.jazzyalex.GHMenuStars` suite.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/GitHubRepoAccessTests/testPollingServiceAcceptsInjectedRepoAccess 2>&1 | tail -5
```
Expected: **BUILD FAILURE**, `extra argument 'repoAccess' in call`.

- [ ] **Step 3: Write minimal implementation**

`GHMenuStars/AppDelegate.swift` — add after the `gitHubClient` lazy property:

```swift
    /// One shared instance: the PAT-dead and double-404 latches are per-instance,
    /// so a second one would retry tokens the first already knows are dead.
    private lazy var repoAccess = GitHubRepoAccess(
        client: gitHubClient,
        patProvider: { KeychainTokenStore.loadGitHubPAT() },
        ambientProvider: { KeychainTokenStore.loadGitHubOAuthToken() }
    )
```

and pass `repoAccess: repoAccess` into the `RepoPollingService(...)` construction.

`GHMenuStars/Services/RepoPollingService.swift` — add a stored property and init parameter:

```swift
    private let repoAccess: GitHubRepoAccess
```

Add `repoAccess: GitHubRepoAccess,` to the init signature after `gitHubClient:`, and `self.repoAccess = repoAccess` to the body.

`GHMenuStars/PreferencesWindow.swift` — add `repoAccess: GitHubRepoAccess` to `show(...)` and forward it into `SettingsView`. Update the `PreferencesWindow.shared.show(...)` call sites in `AppDelegate.swift` / `StatusItemController.swift` to pass `repoAccess:`.

`GHMenuStars/SettingsView.swift` — add:

```swift
    let repoAccess: GitHubRepoAccess
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**. Full suite — this task changes shared initialisers, so a narrow filter would hide breakage.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/AppDelegate.swift GHMenuStars/PreferencesWindow.swift GHMenuStars/Services/RepoPollingService.swift GHMenuStars/SettingsView.swift GHMenuStarsTests/GitHubRepoAccessTests.swift
git commit -m "refactor: wire shared GitHubRepoAccess through app composition

One instance: the latches are per-instance state, so a second would
retry tokens the first knows are dead."
```

---

### Task 9: Polling — delete the guard, route via the seam, skip star fetches

**Files:**
- Modify: `GHMenuStars/Services/RepoPollingService.swift:128-200`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: `GitHubRepoAccess.fetchRepo(owner:name:etag:knownPrivate:repoID:)` → `Outcome` (Task 5); `RepoSnapshot.isPrivate` (Task 3); `GitHubClient.fetchReleases(...optionalAuthToken:)` and `fetchMaintainerRadar(...optionalAuthToken:)` (Task 4).
- Produces: `refresh(repo:)` populates `RepoSnapshot.isPrivate` and threads the winning token to releases + radar.

This is where the feature actually turns on. Three things must happen together:
1. `guard !repoResult.value.private else { throw ... }` at `:138` is **deleted**.
2. The winning token from the `Outcome` is threaded into **both** the releases fetch (`:152`) and the radar fetch (`:177`) — otherwise the radar goes out on OAuth and blanks silently.
3. Stargazer/fork fetches are skipped for private repos — the bulk of the per-poll budget, counting something never displayed.

Also: on a flip, pass `etag: nil` to the **releases** fetch in the *same* poll. `apply(snapshot:)`'s reset (Task 3) fires too late to protect the releases call that already went out with a cross-identity ETag.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/ServiceLogicTests.swift`:

```swift
@MainActor
func testPrivateRepoPollSkipsStargazerAndForkRequestsAndUsesPATEverywhere() async throws {
    var paths: [String] = []
    var radarTokens: [String?] = []
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.handler = { request in
        let path = request.url?.path ?? ""
        paths.append(path)
        if path.contains("search") || path.contains("commits") || path.contains("runs") {
            radarTokens.append(request.value(forHTTPHeaderField: "Authorization"))
        }
        if path.hasSuffix("/repos/o/n") {
            return .init(data: Data(#"{"full_name":"o/n","stargazers_count":0,"forks_count":0,"private":true}"#.utf8))
        }
        if path.contains("releases") { return .init(data: Data("[]".utf8)) }
        return .init(data: Data(#"{"total_count":0,"items":[],"workflow_runs":[]}"#.utf8))
    }
    let client = GitHubClient(session: URLSession(configuration: config))
    let access = GitHubRepoAccess(client: client, patProvider: { "pat" }, ambientProvider: { "oauth" })
    let repoStore = TrackedRepoStore(defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!, legacyDefaults: nil)
    try repoStore.upsertTrackedRepo(TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: true))
    let service = RepoPollingService(
        repoStore: repoStore,
        settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!, legacyDefaults: nil),
        gitHubClient: client,
        repoAccess: access,
        notificationService: NotificationService(),
        soundService: SoundService(),
        animationCoordinator: AnimationCoordinator()
    )

    // refresh(repo:) is made internal in Step 3 for exactly this reason.
    await service.refresh(repo: repoStore.trackedRepos[0])

    XCTAssertFalse(paths.contains { $0.contains("stargazers") }, "private repos have no stars worth spending a request on")
    XCTAssertFalse(paths.contains { $0.contains("forks") })
    XCTAssertFalse(radarTokens.isEmpty, "radar must actually run for a private repo")
    // The whole feature: if any radar call carries the OAuth token it 404s and
    // the optional* wrappers turn it into a blank row with no error.
    XCTAssertTrue(radarTokens.allSatisfy { $0 == "Bearer pat" }, "radar used the wrong identity: \(radarTokens)")
    XCTAssertEqual(repoStore.repo(id: repoStore.trackedRepos.first?.id)?.isPrivate, true)
}
```

**The test must await `refresh(repo:)` directly, and Step 3 makes it internal to allow that.** Both public entry points — `refreshNow()` (`:66`) and `refreshNow(repoID:)` (`:91`) — are fire-and-forget: they spawn an inner `Task` and return immediately. Calling either from a test races the detached work, so every assertion runs against an empty `requestedPaths` and the test **passes while testing nothing** — a false green, which is worse than a failure. Change `private func refresh(repo:)` (`:128`) to `func refresh(repo:)`.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testPrivateRepoPollSkipsStargazerAndForkRequestsAndUsesPATEverywhere 2>&1 | tail -8
```
Expected: **FAIL** — the repo is rejected by the `private` guard, so no radar call ever happens and `radarTokens` is empty.

- [ ] **Step 3: Write minimal implementation**

In `GHMenuStars/Services/RepoPollingService.swift`, first drop `private` from `refresh(repo:)` at `:128` so the test can await it:

```swift
    // internal, not private: the public refreshNow() entries are fire-and-forget,
    // so tests must await this directly or they race the detached Task.
    func refresh(repo: TrackedRepo) async {
```

Then replace the repo-fetch block (lines 135-146) with:

```swift
            let isPrivate: Bool
            let authToken: String?
            var didFlipVisibility = false
            do {
                let repoETagForRequest = repo.lastForks == nil ? nil : repo.etagRepo
                let outcome = try await repoAccess.fetchRepo(
                    owner: repo.owner,
                    name: repo.name,
                    etag: repoETagForRequest,
                    knownPrivate: repo.isPrivate,
                    repoID: repo.id
                )
                switch outcome {
                case .fetched(let repoResult, let fetchedPrivate, let token):
                    isPrivate = fetchedPrivate
                    authToken = token
                    didFlipVisibility = fetchedPrivate != repo.isPrivate
                    // Private repos: nothing to count, so don't pay for it.
                    stars = fetchedPrivate ? 0 : repoResult.value.stargazersCount
                    forks = fetchedPrivate ? 0 : repoResult.value.forksCount
                    repoETag = repoResult.etag ?? repoETag
                    latestRateLimitState = repoResult.rateLimitState ?? latestRateLimitState
                case .notModified(let token):
                    // 304 has no body, so privacy can't be refreshed — keep what we stored.
                    isPrivate = repo.isPrivate
                    authToken = token
                    stars = repo.lastStars ?? 0
                    forks = repo.lastForks ?? 0
                }
            }
```

Note `stars`/`forks` are already declared `let` at `:133-134`; keep those declarations and remove the now-dead `catch GitHubError.notModified` block that the `Outcome` enum replaces.

Thread the token into releases, and drop the ETag on a flip:

```swift
                let releasesResult = try await gitHubClient.fetchReleases(
                    owner: repo.owner,
                    name: repo.name,
                    // A flip invalidates the ETag: it was minted under the other
                    // identity, and apply(snapshot:) resets too late to help the
                    // request already going out here.
                    etag: didFlipVisibility ? nil : repo.etagReleases,
                    optionalAuthToken: authToken
                )
```

Thread the token into the radar (`:177`):

```swift
            async let maintainerRadar = gitHubClient.fetchMaintainerRadar(
                owner: repo.owner,
                name: repo.name,
                activityWindow: activityWindow,
                releaseAnchor: releaseAnchor,
                now: checkedAt,
                optionalAuthToken: authToken
            )
```

Skip the trend fetch for private repos — wrap the `fetchTrendPointsIfNeeded` call (`:171`):

```swift
            async let trendPoints: [RepoTrendPoint]? = isPrivate
                ? nil
                : fetchTrendPointsIfNeeded(for: repo, stars: stars, forks: forks, checkedAt: checkedAt)
```

Adjust the type if `fetchTrendPointsIfNeeded` already returns an optional. Finally set `isPrivate` on the constructed `RepoSnapshot`.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** (full suite).

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Services/RepoPollingService.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(polling): track private repos

Deletes the private-repo guard, routes the repo fetch through
GitHubRepoAccess, and threads the winning token into releases and the
maintainer radar — without which the radar authenticates as OAuth, 404s,
and renders blank rows with no error. Skips stargazer/fork fetches for
private repos."
```

---

### Task 10: Per-metric suppressions

**Files:**
- Modify: `GHMenuStars/Services/RepoPollingService.swift:282-302`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: `TrackedRepo.isPrivate` (Task 3).
- Produces: no new API.

**The trap:** the sound block is gated on `starSoundThreshold.isMet(starsDelta:downloadsDelta:downloads:)` and the celebration block on `celebrationMode != .off` — **both fire on download milestones**. `RepoDelta.hasCelebrationIncrease` is `starsDelta > 0 || downloadsDelta > 0` (`RepoDelta.swift:13`). Wrapping either block in `!repo.isPrivate` silently kills download celebrations for private repos. Gate the **star-driven trigger**, not the block.

**Star-ask needs no change.** It asks the user to star *Stargazer Bar itself* (`RepoPollingService.swift:324` opens `AppExternalLinks.gitHubRepository`), and its `downloadIncrease >= 20` trigger is a legitimate moment for a private repo. Leave it alone.

- [ ] **Step 1: Write the failing test**

Append to `GHMenuStarsTests/ServiceLogicTests.swift`:

```swift
@MainActor
func testPrivateRepoKeepsDownloadCelebrationsButNotStarNotifications() {
    // The regression a blanket `!isPrivate` around these blocks would cause:
    // download milestones are legitimate for private repos.
    var settings = AppSettings()
    settings.notifyOnStarIncrease = true
    settings.playSoundOnStarIncrease = true
    settings.celebrationMode = .subtle

    let starOnly = RepoDelta(starsDelta: 5, downloadsDelta: 0)
    let downloadOnly = RepoDelta(starsDelta: 0, downloadsDelta: 50)

    XCTAssertTrue(starOnly.hasStarIncrease)
    XCTAssertFalse(downloadOnly.hasStarIncrease)
    // Both still count as celebrations; only the star path is private-suppressed.
    XCTAssertTrue(downloadOnly.hasCelebrationIncrease,
                  "download celebrations must survive for private repos")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testPrivateRepoKeepsDownloadCelebrationsButNotStarNotifications 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** (it asserts existing `RepoDelta` semantics). It exists to lock the invariant before the block below is edited — if a later change makes it fail, the suppression was written by block instead of by metric.

- [ ] **Step 3: Write minimal implementation**

In `GHMenuStars/Services/RepoPollingService.swift`, at the top of the block at `:282`:

```swift
        let isPrivateRepo = repoStore.trackedRepos.first(where: { $0.id == repoID })?.isPrivate == true
```

Change the star-notification condition (`:283`) from `if delta.hasStarIncrease,` to:

```swift
        if delta.hasStarIncrease, !isPrivateRepo,
```

Change the sound condition (`:289`) to require a non-private star trigger while leaving the download path intact:

```swift
        if settings.playSoundOnStarIncrease,
           settings.celebrationMode != .off,
           settings.starSoundThreshold.isMet(
                starsDelta: isPrivateRepo ? 0 : delta.starsDelta,
                downloadsDelta: delta.downloadsDelta,
                downloads: downloads
           ),
```

Leave the celebration block (`:298-301`) and `presentStarAskIfNeeded` **unchanged** — both are download-legitimate for private repos.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Services/RepoPollingService.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(polling): suppress star cues for private repos, by metric

The sound and celebration blocks fire on download milestones too, so
gating the blocks would have killed download celebrations. Gates the
star-driven trigger only. Star-ask is untouched: it asks users to star
Stargazer Bar itself."
```

---

### Task 11: Share-image guard at the factory

**Files:**
- Modify: `GHMenuStars/Services/Formatters.swift` (`RepoMilestoneShare.make`)
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: `TrackedRepo.isPrivate` (Task 3).
- Produces: `RepoMilestoneShare.make(repo:metric:)` returns `nil` when `repo.isPrivate`.

**Guard the factory, not the menu.** `canShareMilestone` (`StatusMenuBuilder.swift:222`) gates only menu *construction*; the action handlers re-derive the share via `make` (`StatusItemController.swift:264-269`). Guarding one door leaves the other open. Share images exist to be posted publicly — a private repo name must not be one click from a screenshot.

- [ ] **Step 1: Write the failing test**

```swift
func testMilestoneShareRefusesPrivateRepos() {
    // Collaborators can star a private repo, so a real (if unlikely) value can
    // exist here. The factory is the chokepoint: menu construction is not.
    var repo = TrackedRepo(owner: "o", name: "secret-thing", source: .manual, isPrivate: true)
    repo.lastStars = 100
    XCTAssertNil(RepoMilestoneShare.make(repo: repo, metric: .stars))

    var publicRepo = TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: false)
    publicRepo.lastStars = 100
    XCTAssertNotNil(RepoMilestoneShare.make(repo: publicRepo, metric: .stars))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testMilestoneShareRefusesPrivateRepos 2>&1 | tail -5
```
Expected: **FAIL** — `XCTAssertNil` fails; the private repo currently produces a share.

- [ ] **Step 3: Write minimal implementation**

At the top of `RepoMilestoneShare.make(repo:metric:)` in `GHMenuStars/Services/Formatters.swift`:

```swift
        // Share images are built to be posted publicly. Never generate one that
        // carries a private repo's name.
        guard !repo.isPrivate else { return nil }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Services/Formatters.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(share): never build a milestone share for a private repo

Guards the factory rather than menu construction: the action handlers
re-derive the share independently, so a menu-only guard leaves the other
door open."
```

---

### Task 12: Add flow — delete the guard, route via the seam, privacy-aware backfill

**Files:**
- Modify: `GHMenuStars/SettingsView.swift:480-543` (`validateRepo`)
- Modify: `GHMenuStars/SettingsView.swift:545-584` (`backfillDetails`)
- Test: manual — see Step 4

**Interfaces:**
- Consumes: `GitHubRepoAccess.fetchRepo(...)` → `Outcome` (Task 5); `SettingsView.repoAccess` (Task 8); `TrackedRepo.isPrivate` (Task 3).
- Produces: `backfillDetails(owner:name:isPrivate:authToken:stars:forks:latestRelease:checkedAt:)`.

`backfillDetails` is the background path right after a successful add. Left alone it fires the star/fork fetches phase 1 skips **and** fetches the radar on the ambient token — a blank radar for up to a full poll interval, immediately after the user's first success moment. It is the add-time half of success criterion 2.

- [ ] **Step 1: Write the implementation**

In `validateRepo` (`:490-496`), replace the `fetchRepo` call and the guard at `:492`:

```swift
                let outcome = try await repoAccess.fetchRepo(
                    owner: owner, name: name, etag: nil, knownPrivate: false, repoID: nil
                )
                guard case .fetched(let repoResult, let isPrivate, let authToken) = outcome else {
                    // etag: nil was passed, so a 304 is impossible here.
                    throw GitHubError.notFoundOrPrivate
                }
                let releasesResult = try await gitHubClient.fetchReleases(
                    owner: owner, name: name, etag: nil, optionalAuthToken: authToken
                )
                let downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                let stars = isPrivate ? 0 : repoResult.value.stargazersCount
                let forks = isPrivate ? 0 : repoResult.value.forksCount
```

The `guard !repoResult.value.private else { throw GitHubError.notFoundOrPrivate }` line is **deleted**.

Pass `isPrivate: isPrivate` into the `TrackedRepo(...)` construction at `:507`, and update the `backfillDetails` call at `:529`:

```swift
                    backfillDetails(
                        owner: owner, name: name, isPrivate: isPrivate, authToken: authToken,
                        stars: stars, forks: forks, latestRelease: latestRelease, checkedAt: checkedAt
                    )
```

In `backfillDetails`, add the two parameters, thread the token into the radar call, and skip the trend backfill for private repos:

```swift
        // Private repos: no stars or forks to chart, and the radar must carry
        // the token that actually worked — the ambient one cannot see this repo.
        if !isPrivate {
            // ... existing stargazer/fork trend backfill, unchanged ...
        }
```

and on the radar call inside it, add `optionalAuthToken: authToken`.

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild build -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Run the full suite**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 4: Note for the human reviewer**

`validateRepo`/`backfillDetails` are SwiftUI-bound and not unit-testable without a larger refactor that is out of scope. Task 9 covers the same seam on the polling path, which is the higher-traffic one. Flag in the PR that add-time private tracking needs a human check once the flag is flipped in phase 2. **Do not** build to `.deriveddata-test` and `open` it — that bundle is re-signed by `xcodebuild test` and launches invisibly.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/SettingsView.swift
git commit -m "feat(settings): accept private repos in the add flow

Deletes the second private-repo guard and makes backfillDetails
privacy-aware: it skips the star/fork trend and carries the winning token
into the radar, so a freshly added private repo isn't blank until the
next poll."
```

---

### Task 13: `clearAllETags()`

**Files:**
- Modify: `GHMenuStars/Persistence/TrackedRepoStore.swift`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `TrackedRepoStore.clearAllETags()`.

A leaf change with no dependencies. It must precede Task 14, which calls it.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
func testClearAllETagsWipesEveryRepo() throws {
    let store = TrackedRepoStore(defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!, legacyDefaults: nil)
    try store.upsertTrackedRepo(TrackedRepo(owner: "a", name: "1", source: .manual,
                                            etagRepo: "e1", etagReleases: "r1"))
    try store.upsertTrackedRepo(TrackedRepo(owner: "b", name: "2", source: .manual,
                                            etagRepo: "e2", etagReleases: "r2"))

    // A new PAT is a new identity; every stored ETag was minted under the old one.
    store.clearAllETags()

    XCTAssertTrue(store.trackedRepos.allSatisfy { $0.etagRepo == nil && $0.etagReleases == nil })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testClearAllETagsWipesEveryRepo 2>&1 | tail -5
```
Expected: **BUILD FAILURE**, `value of type 'TrackedRepoStore' has no member 'clearAllETags'`.

- [ ] **Step 3: Write minimal implementation**

```swift
    /// Called when the PAT changes: every stored ETag was minted under the old
    /// auth identity, and a 304 against one would serve a body that identity
    /// could see. A stale-ETag miss costs one request; trusting one costs
    /// correctness. Conditional requests that 304 don't consume rate limit, so
    /// this is close to free.
    func clearAllETags() {
        for index in trackedRepos.indices {
            trackedRepos[index].etagRepo = nil
            trackedRepos[index].etagReleases = nil
        }
        saveAll()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Persistence/TrackedRepoStore.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(store): add clearAllETags for PAT identity changes"
```

---

### Task 14: PAT Settings section behind the flag + auth extraction

**Files:**
- Create: `GHMenuStars/Settings/GitHubAuthSettingsView.swift`
- Modify: `GHMenuStars/SettingsView.swift` (remove the extracted auth section)
- Test: manual — see Step 4

**Interfaces:**
- Consumes: `KeychainTokenStore.gitHubPATStore()` (Task 1); `AppSettings.enablePrivateRepos` (Task 2); `GitHubRepoAccess.resetTokenState()` (Task 5); `TrackedRepoStore.clearAllETags()` (Task 13).
- Produces: `GitHubAuthSettingsView` — a `View` taking `settingsStore`, `repoStore`, `repoAccess`.

Copy requirements, all load-bearing:
- The **resource-owner trap**: a PAT owned by a personal account can never reach an org-owned private repo, and it fails as a plain 404 indistinguishable from "not found". Org policy can also block fine-grained PATs entirely.
- Required permissions, all **Read**: Metadata, Contents, Issues, Pull requests, Actions.
- Distinguish this section from OAuth sign-in, which powers the repo picker and uses scope `public_repo`. Users will otherwise paste PATs into the wrong slot.
- Show the expiry from the `github-authentication-token-expiration` header **only when it parses to a plausible future date** — non-expiring PATs are legal and omit it. No countdown, no warning state.
- **Do not** show a "repos reached" count. No endpoint reliably enumerates a fine-grained PAT's grant. (Observed in the spike: a user asked for a one-repo token produced one reaching all 31 of their repos. Assume broad grants.)
- **Do not** advertise commit velocity.

- [ ] **Step 1: Write the implementation**

Create `GHMenuStars/Settings/GitHubAuthSettingsView.swift` containing the OAuth section moved verbatim out of `SettingsView`, plus:

```swift
    @ViewBuilder
    private var privateReposSection: some View {
        // Phase 1 is internal: without this gate a hotfix cut from main would
        // expose private tracking before the menu bar has any answer for it.
        if settingsStore.settings.enablePrivateRepos {
            Section("Private repositories") {
                SecureField("Fine-grained token", text: $patInput)
                HStack {
                    Button("Save") { savePAT() }.disabled(patInput.isEmpty)
                    Button("Remove") { removePAT() }.disabled(!KeychainTokenStore.hasGitHubPAT())
                }
                if repoAccess.isPATDead {
                    // Distinct from the generic not-found copy: after the latch the
                    // ambient fallback 404s, which would otherwise blame the repo
                    // rather than the token.
                    Text("Your private-repo token was revoked or expired — save a new one to resume tracking private repositories.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let status = patStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Create a fine-grained token with Read access to Metadata, Contents, Issues, Pull requests and Actions. Set the resource owner to the organization if the repository belongs to one — a token owned by your personal account cannot see org repositories, and the failure looks identical to \"not found\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func savePAT() {
        do {
            try KeychainTokenStore.gitHubPATStore().saveToken(patInput)
            // A new identity invalidates every stored ETag, and revives both
            // latches. Never diff the old secret to detect a change — the action
            // firing is the signal.
            repoStore.clearAllETags()
            repoAccess.resetTokenState()
            patInput = ""
            validatePAT()
        } catch {
            patStatus = GitHubError.userMessage(for: error)
        }
    }

    private func removePAT() {
        try? KeychainTokenStore.gitHubPATStore().deleteToken()
        repoStore.clearAllETags()
        repoAccess.resetTokenState()
        patStatus = nil
    }
```

`validatePAT()` performs `GET /user` with the stored PAT and sets `patStatus` to the login, appending the expiry only when the `github-authentication-token-expiration` header parses to a future date.

Add `deleteToken()` to `KeychainTokenStore` if absent:

```swift
    func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubError.transport("Keychain delete failed: \(status)")
        }
    }
```

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild build -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Verify SettingsView shrank**

Run:
```bash
wc -l GHMenuStars/SettingsView.swift GHMenuStars/Settings/GitHubAuthSettingsView.swift
```
Expected: `SettingsView.swift` is materially below its starting 911 lines; the auth code lives in the new file and is not duplicated.

- [ ] **Step 4: Run the full suite**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**. With the flag off the section does not render, so no existing UI test should change.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/Settings/GitHubAuthSettingsView.swift GHMenuStars/SettingsView.swift GHMenuStars/Persistence/KeychainTokenStore.swift GHMenuStars.xcodeproj
git commit -m "feat(settings): PAT section behind enablePrivateRepos, extract auth UI

Saving or removing the PAT clears all ETags (minted under a different
identity) and both latches. Help text calls out the resource-owner trap,
which fails as an indistinguishable 404."
```

---

### Task 15: Menu shape and error copy

**Files:**
- Modify: `GHMenuStars/StatusMenuBuilder.swift:14`, `:80-118`, `:124-137`, `:292`
- Modify: `GHMenuStars/SettingsView.swift:801-806` (`RepositoryRow.metricsText`)
- Modify: `GHMenuStars/GitHub/GitHubClient.swift:20-21`
- Test: `GHMenuStarsTests/ServiceLogicTests.swift` (append)

**Interfaces:**
- Consumes: `TrackedRepo.isPrivate` (Task 3).
- Produces: no new API.

Four changes:
1. `:14` — *"Add up to 5 **public** repositories in Settings."* is no longer true.
2. `:80-118` — `repoLine` renders `☆ … ⤓ …` for every repo and bold-ranges off star numbers. Private repos: downloads + radar, no star glyph.
3. `:124-137` — `trendMenu` must be **omitted** for private repos. Since the star/fork fetches are skipped, `trendPoints` stays empty forever and the submenu renders a permanent "Loading GitHub history…" (`:720-728`). A spinner that never resolves is worse than no row.
4. `:292` — suppress `+N ⭐` on the radar activity row.

Plus the error copy at `GitHubClient.swift:21`, which currently claims *"V1 tracks public repositories only"* — now false.

- [ ] **Step 1: Write the failing test**

```swift
func testNotFoundErrorCopyNoLongerClaimsPublicOnly() {
    let message = GitHubError.userMessage(for: GitHubError.notFoundOrPrivate)
    XCTAssertFalse(message.contains("V1 tracks public repositories only"),
                   "the app tracks private repos now")
    XCTAssertFalse(message.contains("public repositories only"))
    // Must point somewhere actionable: the 404 is indistinguishable between
    // "doesn't exist", "no token can see it", and "wrong PAT resource owner".
    XCTAssertTrue(message.lowercased().contains("settings"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test -only-testing:GHMenuStarsTests/ServiceLogicTests/testNotFoundErrorCopyNoLongerClaimsPublicOnly 2>&1 | tail -5
```
Expected: **FAIL** — the string still says "V1 tracks public repositories only".

- [ ] **Step 3: Write minimal implementation**

`GHMenuStars/GitHub/GitHubClient.swift:20-21`:

```swift
        case GitHubError.notFoundOrPrivate:
            return "Repository not found, or no token in Settings can see it. For a private repository, add a fine-grained token in Settings — and if it belongs to an organization, make sure the token's resource owner is that organization."
```

`GHMenuStars/StatusMenuBuilder.swift:14`:

```swift
        menu.addItem(titleItem("Add up to \(TrackedRepoStore.maximumTrackedRepos) repositories in Settings."))
```

In `repoLine`, branch on `repo.isPrivate` to build a downloads-only line with no `☆` segment, and skip the star bold-range logic for that branch. In `trendMenu`, return `nil`/skip when `repo.isPrivate`. At `:292`, wrap the `+N ⭐` append in `if !repo.isPrivate`. In `RepositoryRow.metricsText`, return a downloads-only string for private repos.

- [ ] **Step 4: Run the full suite**

Run:
```bash
xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**. The StatusMenu structure tests (`ServiceLogicTests.swift:493, 546, 580, 862`) may need updating where menu items shift — verify each change is caused by the private branch and not a public-repo regression.

- [ ] **Step 5: Commit**

```bash
git add GHMenuStars/StatusMenuBuilder.swift GHMenuStars/SettingsView.swift GHMenuStars/GitHub/GitHubClient.swift GHMenuStarsTests/ServiceLogicTests.swift
git commit -m "feat(menu): private repo line shape and honest error copy

Drops the trend submenu for private repos — with star/fork fetches
skipped it would spin on 'Loading GitHub history' forever. Rewrites the
404 copy, which claimed the app tracks public repos only."
```

---

## Definition of done

Phase 1 is complete when all of these hold:

1. A private repo can be added by `owner/name` with a valid PAT and polls without error.
2. Its maintainer radar populates PRs, issues, unanswered issues and CI — at add time, not just on the next poll.
3. No star glyph, no star notification/sound/animation, no share image — while **download** sounds and celebrations still fire.
4. Removing or revoking the PAT gives a clear, actionable error, and costs one call per poll thereafter, not two.
5. Public tracking is byte-for-byte unchanged without a PAT, proven by `testPublicRepoFetchDoesNotReadToken` and `testPublicRepoFetchUsesOptionalTokenWhenAvailable` still passing **unmodified**.
6. A repo that flips visibility in either direction recovers on the next poll with no user action — including when the PAT was revoked before the flip.
7. With `enablePrivateRepos` off, a build cut from main is indistinguishable from today.
8. Full suite green: `xcodebuild test -project GHMenuStars.xcodeproj -scheme GHMenuStars -derivedDataPath .deriveddata-test`

## Deferred to phase 2 — do not build here

- Cross-branch commit counting via `/repos/{o}/{r}/activity` + active-ref fan-out + SHA dedupe. `/commits` is default-branch-only; measured 0 on `main` vs 100+ on a feature branch in the same week. This also fixes the radar's existing `recentCommits` under-reporting for **public** repos.
- `CommitActivityWindow` setting and commit charting.
- Flipping `enablePrivateRepos` on.

## Deferred to phase 3

- `MenuBarDisplayMode.selectedRepoCommits` and any menu bar answer for a selected private repo.
- **Downgrade hazard to handle there:** `decodeIfPresent` *throws* on a present-but-unknown raw value, so running an older build after selecting a new mode fails the whole `AppSettings` decode and resets every setting (`SettingsStore.swift:168`). Not triggerable in phase 1, which adds no new enum cases to persisted settings.
