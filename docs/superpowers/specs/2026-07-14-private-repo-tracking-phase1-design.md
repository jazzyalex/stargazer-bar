# Private repo tracking — Phase 1: PAT auth + private repos on existing plumbing

**Date:** 2026-07-14
**Status:** Design, approved for planning
**Phase:** 1 of 3

---

## Goal

Let Stargazer Bar track **private** repositories. Today it refuses them outright: two
`guard !repoResult.value.private` lines reject any private repo at add time and on every poll.

Private repos have no meaningful stars, so the tracked metric shifts to the **maintainer radar**
(open/new PRs, new issues, unanswered issues, CI status) plus **commit velocity**. Phase 1 delivers
private tracking and the radar. Commit velocity is phase 2; the menu bar commits mode is phase 3.

## Scope

**In scope (phase 1):**
- Fine-grained PAT storage in Keychain, separate from the OAuth token
- Repo-aware token resolution with 404-retry
- Removing the two private-repo guards; persisting `isPrivate`
- Visibility flip handling (public↔private) in both directions
- Suppressing star-shaped behaviour for private repos
- Error copy, menu copy, Settings UI
- Extracting the GitHub-auth portion of `SettingsView`

**Explicitly out of scope:**
- Cross-branch commit counting → **phase 2** (see Known Limitations)
- `CommitActivityWindow` setting, commit charting → **phase 2**
- `MenuBarDisplayMode.selectedRepoCommits` → **phase 3**
- Widening the OAuth device-flow scope (stays `public_repo`)
- Commit-triggered notifications or sounds (not requested)

## Evidence base

Every API claim below was verified on 2026-07-14 against real private repos
(`jazzyalex/Triada`, `jazzyalex/Tennis-Tracker`) with a fine-grained PAT. The spike existed
because the biggest risk — whether `/search/issues` sees private repos — is **silently swallowed**
by the `optional*` wrappers ([GitHubClient.swift:423](../../../GHMenuStars/GitHub/GitHubClient.swift#L423)),
so a failure would have shipped as blank radar rows with no error.

| Claim | Result |
|---|---|
| `/search/issues` sees private repos with a FG PAT | **Yes.** search `is:issue is:open` = 1 vs REST control = 1; `is:pr is:open` = 0 vs 0 |
| `created:>=` qualifier works | **Yes.** Boundary verified: issue dated 2025-08-16 counts in a 365d window, not in 90d |
| `comments:0` (unanswered) works | **Yes.** Returns 1 |
| Permissions Contents/Issues/PRs/Actions/Metadata (all Read) sufficient | **Yes.** `/commits`, `/actions/runs`, `/releases` all HTTP 200 |
| A FG PAT reads public repos **outside** its grant | **Yes.** `rust-lang/rust` → 200. Docs: *"Tokens always include read-only access to all public repositories"* |
| `github-authentication-token-expiration` header usable | **Yes.** Returned a real date (`2026-07-22`). A reported go-github bug did not reproduce |
| FG PATs are always ≤1yr | **No.** Non-expiring tokens are allowed since the March 2025 GA. UI must handle a missing expiry |
| Search rate limit is a separate bucket | **Yes.** 30/30, distinct from core 5000 |

## Design

### 1. PAT storage

`KeychainTokenStore` is already parameterized by `service`, but hardcodes
`private let account = "github-oauth"` ([KeychainTokenStore.swift:13](../../../GHMenuStars/Persistence/KeychainTokenStore.swift#L13)).

Change `account` to a stored property defaulting to `"github-oauth"`. The default keeps the
memberwise init and every existing `KeychainTokenStore(service:)` call site working unchanged, so
there is **no Keychain migration** and the legacy-OAuth migration path
([SettingsView.swift:715-727](../../../GHMenuStars/SettingsView.swift#L715)) is untouched.

Add:

```swift
static let gitHubPATService = "StargazerBar.GitHubPAT"
static func gitHubPATStore() -> KeychainTokenStore {
    KeychainTokenStore(service: gitHubPATService, account: "github-pat")
}
static func loadGitHubPAT() -> String?
static func hasGitHubPAT() -> Bool
```

The `(service, account)` pair is the Keychain primary key, so a distinct `service` alone would
suffice — the `account` rename is for honesty, not correctness. A token stored under
`account: "github-oauth"` that is not an OAuth token is a trap for the next reader.

### 2. Token resolution seam

**Do not** collapse to "prefer PAT everywhere" even though the spike proves one PAT could serve
every request. A revoked or expired PAT would then 401 *public* tracking too, and
`fetchAccessiblePublicRepos` ([GitHubClient.swift:319](../../../GHMenuStars/GitHub/GitHubClient.swift#L319))
must stay on OAuth or the repo picker shrinks to only the PAT's grant.

**Do not** replace `GitHubClient`'s ambient `tokenProvider`/`optionalTokenProvider` closures either.
Instead extend the existing `optionalAuthToken` parameter — which `request()` already accepts
([GitHubClient.swift:524](../../../GHMenuStars/GitHub/GitHubClient.swift#L524)) and the radar calls
already thread — to `fetchRepo` and `fetchReleases`, defaulted to `nil`:

```swift
func fetchRepo(owner: String, name: String, etag: String?, optionalAuthToken: String? = nil) async throws -> GitHubHTTPResult<GitHubRepoResponse>
func fetchReleases(owner: String, name: String, etag: String?, optionalAuthToken: String? = nil) async throws -> GitHubHTTPResult<[GitHubRelease]>
```

The default preserves current behaviour and spares ~15 `GitHubClient` construction sites in
`GitHubModelTests` plus the ad-hoc client at [SettingsView.swift:698](../../../GHMenuStars/SettingsView.swift#L698).

New type `GitHubRepoAccess` owns the resolution rule:

```swift
struct GitHubRepoAccess {
    let client: GitHubClient
    let patProvider: () -> String?

    struct Outcome {
        var result: GitHubHTTPResult<GitHubRepoResponse>
        var isPrivate: Bool      // authoritative, from result.value.private
        var token: String?       // the token that worked — reuse for releases/radar
    }

    func fetchRepo(owner: String, name: String, etag: String?, knownPrivate: Bool) async throws -> Outcome
}
```

Rule:
1. If `knownPrivate` and a PAT exists → try PAT first. Otherwise try the ambient token (OAuth or none).
2. On `.notFoundOrPrivate` (404), if a PAT exists and was not already tried → **retry once with the PAT**.
3. On any 2xx → set `isPrivate` from `result.value.private`, **always**, regardless of what was stored.
4. Return the winning token so the repo's releases and radar calls reuse it rather than re-deriving.

**Why the retry is unavoidable:** GitHub 404s identically for "does not exist" and "you cannot see
it" — by design, so private repos aren't enumerable. At add time there is no `TrackedRepo` yet and
the user typed a bare `owner/name`, so privacy is unknowable until a fetch **succeeds**. The same
hole reopens on a public→private flip, where the stored `isPrivate: false` would pick the OAuth
token, 404, and never learn otherwise.

### 3. Removing the guards, persisting `isPrivate`

The two guards are the load-bearing change:

- [SettingsView.swift:492](../../../GHMenuStars/SettingsView.swift#L492) — add flow
- [RepoPollingService.swift:138](../../../GHMenuStars/Services/RepoPollingService.swift#L138) — every poll

Both are deleted. Each call site instead routes through `GitHubRepoAccess` and records
`isPrivate` on the `TrackedRepo`.

`TrackedRepo.isPrivate: Bool` — decoded with `decodeIfPresent(...) ?? false`, matching the
existing hand-written `init(from:)` style ([TrackedRepo.swift:398](../../../GHMenuStars/Models/TrackedRepo.swift#L398)).
Stored repos predate private support, so `false` is the correct default and migration is free.

Add `isPrivate` to `RepoSnapshot`, and carry it in **both**:
- `TrackedRepoStore.upsertTrackedRepo` ([TrackedRepoStore.swift:42](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L42)) — copies fields member-by-member; a new field not added here is silently dropped on re-add
- `TrackedRepoStore.apply(snapshot:to:)` ([TrackedRepoStore.swift:101](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L101))

### 4. Visibility flips

Both directions must work, driven by rule 3 above (`isPrivate` always refreshed from a 2xx):

- **public → private:** stored `isPrivate: false` → OAuth → 404 → PAT retry → 200 with `private: true` → persist `isPrivate: true`. Recovers automatically.
- **private → public:** stored `isPrivate: true` → PAT → 200 with `private: false` → persist `isPrivate: false`. Also recovers if the PAT was since revoked, because the 404 retry ladder falls back to the ambient token.
- **private, PAT removed:** 404 on both attempts → repo enters the "needs a token" error state (§7), keeps its last known values, and does not get deleted.

**ETags on flips and token changes:** stored `etagRepo`/`etagReleases` were minted under a
different identity. Conditional requests that 304 don't consume rate limit, so the cost of a
stale-ETag miss is one request; the cost of trusting a cross-identity ETag is serving wrong data.
Reset both to `nil` at exactly two points:

1. **In `apply(snapshot:)`**, when `snapshot.isPrivate != repo.isPrivate` — clears that one repo.
2. **In the PAT save/remove action** (not on a token-value comparison — never read the Keychain to
   diff secrets) — clears `etagRepo` and `etagReleases` on **all** tracked repos. Saving over an
   existing PAT counts as a change; the action fires either way, so "replaced" needs no detection.

Note the existing conditional-request quirk at
[RepoPollingService.swift:136](../../../GHMenuStars/Services/RepoPollingService.swift#L136)
(`repo.lastForks == nil ? nil : repo.etagRepo`) — the reset must not fight it.

### 5. Settings UI

New **Private repositories** section:

- Secure paste field for the PAT, Save / Remove buttons
- Validate on save: `GET /user` with the PAT. On success show the login, and the expiry from the
  `github-authentication-token-expiration` response header **only when it parses to a plausible
  future date** — non-expiring tokens are legal and omit it. Never render a countdown or a broken date.
- **Do not** display a "repos reached" count. No endpoint reliably enumerates a FG PAT's grant.
  Validate against the repos actually tracked instead.
- Help text must call out the **resource-owner trap**: a PAT owned by a personal account can never
  reach an **org-owned** private repo, and it fails as a plain 404 indistinguishable from "not found".
  Org policy can also block FG PATs entirely.
- The section sits next to the existing OAuth sign-in, which does something different (it powers the
  repo picker, scope `public_repo`). Copy must distinguish them or users will paste PATs into the
  wrong slot.

**Refactor:** [SettingsView.swift](../../../GHMenuStars/SettingsView.swift) is 911 lines before this
change. Extract the GitHub-auth portion (OAuth sign-in + the new PAT section) into
`Settings/GitHubAuthSettingsView.swift`. This is scoped to code phase 1 already edits — not a
general cleanup.

### 6. Suppressions for private repos

Gate on `repo.isPrivate`:

| Behaviour | Location | Reason |
|---|---|---|
| Star notification | [RepoPollingService.swift:284](../../../GHMenuStars/Services/RepoPollingService.swift#L284) | No stars to notify about |
| Star sound | [RepoPollingService.swift:289](../../../GHMenuStars/Services/RepoPollingService.swift#L289) | Same |
| Star animation | `.starIncrease` mapping, [RepoPollingService.swift:9](../../../GHMenuStars/Services/RepoPollingService.swift#L9) | Same |
| Star-ask prompt | `starAskPromptStatus` | Cannot star a private repo you own |
| Milestone share image | [StatusMenuBuilder.swift:222](../../../GHMenuStars/StatusMenuBuilder.swift#L222) `canShareMilestone` | **Privacy.** Share images exist to be posted publicly; a private repo name must not be one click from Twitter |
| Trend chart (stars/forks) | Chart rendering | Always flat at zero — noise, not signal |
| `+N ⭐` on the radar activity row | [StatusMenuBuilder.swift:292](../../../GHMenuStars/StatusMenuBuilder.swift#L292) | Same |

The share suppression is *nearly* moot — `RepoMilestoneShare.make` already returns nil at
`currentValue <= 0`. But collaborators **can** star a private repo, so the explicit guard is one
line of insurance against a real (if unlikely) leak.

**Skip the stargazer and fork fetches entirely for private repos.** They are the bulk of the
per-poll request budget and there is nothing to count.

Per-repo menu line ([StatusMenuBuilder.swift:80](../../../GHMenuStars/StatusMenuBuilder.swift#L80))
renders `☆ … ⤓ …` for every repo, and its bold-ranges logic (86-118) keys off star numbers. Private
repos need their own line shape. Phase 1: show downloads and radar only, no star glyph.

### 7. Error handling and copy

[GitHubClient.swift:21](../../../GHMenuStars/GitHub/GitHubClient.swift#L21) currently reads
*"Repository was not found or is private. V1 tracks public repositories only."* — now false.
Replace with copy that names the real causes and points at Settings: repo does not exist, **or** it
is private and no token in Settings can reach it, **or** it is org-owned and the PAT's resource
owner is wrong.

Distinguish a PAT 401 from an OAuth 401: *"Your private-repo token was revoked or expired — update
it in Settings."* A 401 on the PAT path must **not** be reported as a general auth failure, and must
not disturb public repo tracking.

**No expiry state machine in phase 1.** No countdown, no notifications, no proactive warning. The
header is available and the Settings row shows it when parseable; that is the whole feature. FG PATs
can be non-expiring, which removes most of the justification for anything richer.

Missing individual permissions already degrade gracefully via the `optional*` radar wrappers — a PAT
without Actions:Read simply yields a blank CI row rather than an error.

### 8. Rate limits

All of a user's PATs and OAuth tokens **share one 5,000/hr core bucket**, so the existing single
`RateLimitState` remains correct with two tokens in play. No change needed.

Search is a separate 30/min bucket. The radar fires **4** search calls per repo per poll
([GitHubClient.swift:343-364](../../../GHMenuStars/GitHub/GitHubClient.swift#L343)); at the 5-repo
cap ([TrackedRepoStore.swift:10](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L10)) that
is 20 per refresh — safe on the 10-minute default poll, but a "Check Now" fired immediately after a
scheduled poll can cross 30/min. The resulting 403 is swallowed by `optional*` into blank rows
without updating `rateLimitState`. **Pre-existing**, not introduced here, but it matters more once
the radar is the whole product for a repo. Phase 1 records it; a fix is not in scope.

## Known limitations (deferred, deliberate)

**Commit counts under-report on feature-branch workflows.** `commitCount`
([GitHubClient.swift:458](../../../GHMenuStars/GitHub/GitHubClient.swift#L458)) calls
`/repos/{o}/{r}/commits`, which only covers the **default branch**. Measured on
`jazzyalex/Tennis-Tracker`: `main` had **0** commits in 7 days while `rebuild-foundation` had
**100+**. The radar's `recentCommits` row will read 0 for a private repo whose work lives on a
feature branch.

This is **pre-existing** and already affects public repos — it is not a regression introduced by
phase 1. It is tolerable in phase 1 because the radar's commit row is a garnish beside PRs, issues
and CI. It becomes **fatal** in phase 3, where commits are the menu bar headline.

Phase 2 fixes it for public and private repos alike: `GET /repos/{o}/{r}/activity?time_period=…`
returns cross-branch push activity in one call (verified: HTTP 200, correctly surfaced
`rebuild-foundation`), narrowing the fan-out to *active* refs only — 2 calls for Tennis-Tracker, not
1-per-branch. Results must be **deduped by SHA**: a branch cut from `main` replays main's shared
history, so summing per-branch counts over-counts badly in the common case. `/search/commits` is not
an option; it indexes only the default branch (verified: returned 0 where the true count was 100+).

Phase 1 must therefore **not** advertise commit velocity in UI copy.

## Testing

New:
- `GitHubRepoAccess` resolution: private+PAT → PAT; public → ambient; 404→PAT-retry → success sets `isPrivate: true`; 404 on both → `.notFoundOrPrivate`; PAT tried at most once
- Flip handling both directions; PAT-removed keeps last known values
- ETag reset on flip and on PAT add/remove/replace
- `TrackedRepo` decodes legacy JSON with no `isPrivate` → `false`
- `upsertTrackedRepo` and `apply(snapshot:)` round-trip `isPrivate`
- Each suppression rule (notification, sound, animation, share, star-ask)
- Private repo poll issues **no** stargazer/fork request
- Keychain: PAT and OAuth stores do not collide

Existing tests that will break and need updating:
- `testPublicRepoFetchDoesNotReadToken` / `testPublicRepoFetchUsesOptionalTokenWhenAvailable`
  ([GitHubModelTests.swift:153, 176](../../../GHMenuStarsTests/GitHubModelTests.swift)) — their premise
  *is* the token-selection behaviour being changed
- `testTrackedReposMigrateFromLegacyBundleDefaults` (:472) — add a no-`isPrivate` fixture
- StatusMenu structure tests — the private-repo line shape shifts menu items

## Persistence hazards (noted, not fixed)

1. **Silent wipe on decode failure.** `TrackedRepoStore` decodes with `try?` and falls back to `[]`
   ([TrackedRepoStore.swift:26](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L26));
   `SettingsStore` falls back to defaults. Any decode bug in a new field destroys all tracked repos
   or all settings with no error surfaced. Pre-existing, but phase 1 is the first edit to these
   Codables since the footgun was loaded — the new-field tests above are the mitigation.
2. **Downgrade hazard (phase 3, recorded here).** `decodeIfPresent` **throws** on a present-but-unknown
   raw value, so running an older build after selecting a future `.selectedRepoCommits` mode fails the
   whole `AppSettings` decode and resets every setting
   ([SettingsStore.swift:168](../../../GHMenuStars/Persistence/SettingsStore.swift#L168)). Not
   triggerable in phase 1, which adds no new enum cases to persisted settings.

## Files touched

| File | Change |
|---|---|
| `Persistence/KeychainTokenStore.swift` | `account` becomes a defaulted property; PAT service + helpers |
| `GitHub/GitHubClient.swift` | `optionalAuthToken` on `fetchRepo`/`fetchReleases`; error copy |
| `GitHub/GitHubRepoAccess.swift` | **New.** Resolution + 404-retry seam |
| `Models/TrackedRepo.swift` | `isPrivate` + decode |
| `Models/RepoSnapshot.swift` | `isPrivate` |
| `Persistence/TrackedRepoStore.swift` | Carry `isPrivate` in upsert + apply |
| `Services/RepoPollingService.swift` | Remove guard; route via `GitHubRepoAccess`; skip stargazers/forks; gate suppressions |
| `SettingsView.swift` | Remove guard; route via `GitHubRepoAccess`; shrink via extraction |
| `Settings/GitHubAuthSettingsView.swift` | **New.** OAuth + PAT sections |
| `StatusMenuBuilder.swift` | Private repo line shape; share guard; copy at :14 |
| `GHMenuStarsTests/*` | Per Testing above |

## Success criteria

1. A private repo can be added by `owner/name` with a valid PAT, and polls without error.
2. Its maintainer radar populates PRs, issues, unanswered issues and CI (spike-verified as reachable).
3. It shows no star glyph, fires no star notification/sound/animation, and offers no share image.
4. Removing the PAT degrades it to a clear, actionable error — not a crash, not silent staleness,
   not data loss.
5. Public repo tracking is byte-for-byte unchanged for a user who never adds a PAT.
6. A repo that flips visibility in either direction recovers on the next poll with no user action.
