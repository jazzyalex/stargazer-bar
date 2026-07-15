# Private repo tracking — Phase 1: PAT auth + private repos on existing plumbing

**Date:** 2026-07-14
**Status:** Design, approved for planning (revision 2 — post spec review)
**Phase:** 1 of 3

---

## Goal

Let Stargazer Bar track **private** repositories. Today it refuses them outright: two
`guard !repoResult.value.private` lines reject any private repo at add time and on every poll.

Private repos have no meaningful stars, so the tracked metric shifts to the **maintainer radar**
(open/new PRs, new issues, unanswered issues, CI status) plus **commit velocity**. Phase 1 delivers
private tracking and the radar. Commit velocity is phase 2; the menu bar commits mode is phase 3.

## Release posture — read this first

**Phase 1 is an internal milestone. It does not ship a user-visible feature.**

The release gate for anything private-facing is: *a private repo can be the selected menu bar repo
and read correctly.* That is not true until phase 3. Shipping phase 1 to users would mean a
private-only user gets a permanent **"★ 0"** in their menu bar — the default mode is
`.selectedRepoStars` ([SettingsStore.swift:133](../../../GHMenuStars/Persistence/SettingsStore.swift#L133)),
the add flow auto-selects the first repo
([SettingsView.swift:524-526](../../../GHMenuStars/SettingsView.swift#L524)), and
`selectMenuBarRepo` force-sets a star mode
([SettingsView.swift:616-623](../../../GHMenuStars/SettingsView.swift#L616)). The available
stopgaps are all bad: a downloads fallback degrades to `--` for exactly the WIP-repo persona this
feature targets (private repos often have no releases), and a radar attention-count invents menu bar
vocabulary in phase 1 that phase 3 deletes.

**But "internal" is not automatic.** Main stays releasable — a 0.5.x hotfix can cut from it at any
time, especially during Product Hunt launch prep. Phase 1 code merged to main would ship dormant
*except* the PAT Settings section, which is a live door: paste a token, add a private repo, select it
manually, and the star-zero problem arrives on a released build.

**Therefore:** merge to main with the **PAT Settings section behind a single hidden flag, default
off**, flipped on in phase 2. Not a feature-flag system — one bool. This keeps main releasable, gets
phase 1 code exercised, and makes success criterion 5 (public tracking byte-identical without a PAT)
trivially true for every release cut in between. A long-lived feature branch is the alternative and
is worse: it rots across a launch during which hotfixes will be cut from main repeatedly.

Whether phases 2 and 3 merge into one released unit is **deliberately not decided here**. That call
belongs at the 2/3 boundary, once `/activity`'s data quality is known.

## Scope

**In scope (phase 1):**
- Fine-grained PAT storage in Keychain, separate from the OAuth token
- Repo-aware token resolution with 404-retry and a PAT-dead latch
- Removing the two private-repo guards; persisting `isPrivate`
- Visibility flip handling (public↔private) in both directions
- Suppressing star-shaped behaviour for private repos, **by metric, not by code block**
- Error copy, menu copy, Settings UI behind the hidden flag
- Extracting the GitHub-auth portion of `SettingsView`

**Explicitly out of scope:**
- Cross-branch commit counting → **phase 2** (see Known Limitations)
- `CommitActivityWindow` setting, commit charting → **phase 2**
- `MenuBarDisplayMode.selectedRepoCommits` → **phase 3**
- Any menu bar answer for a selected private repo → **phase 3** (the hidden flag is why this is safe)
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

Change it to **`var account: String = "github-oauth"`** — internal, and a `var`, not a `let`.
This is load-bearing, not style: a `let` with an initial value is **excluded from the synthesized
memberwise init**, so `KeychainTokenStore(service:account:)` would not compile if `account` stayed
a `let`. As a defaulted `var` it joins the memberwise init while every existing
`KeychainTokenStore(service:)` call site keeps compiling unchanged
([KeychainTokenStore.swift:16](../../../GHMenuStars/Persistence/KeychainTokenStore.swift#L16),
[SettingsView.swift:721](../../../GHMenuStars/SettingsView.swift#L721),
`ServiceLogicTests.swift:1023` — including the trailing-closure form). There is **no Keychain
migration** and the legacy-OAuth migration path
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

**Do not** collapse to "prefer PAT everywhere". A revoked or expired PAT would then fail *public*
tracking too, and `fetchAccessiblePublicRepos`
([GitHubClient.swift:319](../../../GHMenuStars/GitHub/GitHubClient.swift#L319)) must stay on OAuth or
the repo picker shrinks to only the PAT's grant.

**Do not** replace `GitHubClient`'s ambient `tokenProvider`/`optionalTokenProvider` closures either.
Instead extend the existing `optionalAuthToken` parameter — which `request()` already accepts
([GitHubClient.swift:524](../../../GHMenuStars/GitHub/GitHubClient.swift#L524)) — to the three
public entry points a private repo needs, all defaulted to `nil`:

```swift
func fetchRepo(owner: String, name: String, etag: String?, optionalAuthToken: String? = nil) async throws -> GitHubHTTPResult<GitHubRepoResponse>
func fetchReleases(owner: String, name: String, etag: String?, optionalAuthToken: String? = nil) async throws -> GitHubHTTPResult<[GitHubRelease]>
func fetchMaintainerRadar(owner: String, name: String, activityWindow: MaintainerRadarActivityWindow, releaseAnchor: Date? = nil, now: Date = Date(), optionalAuthToken: String? = nil) async -> RepoMaintainerRadar
```

**`fetchMaintainerRadar` is the critical one and is easy to miss.** Its private helpers already
thread `optionalAuthToken`, but the *public entry point* does not — it derives the token itself from
the ambient provider at [GitHubClient.swift:342](../../../GHMenuStars/GitHub/GitHubClient.swift#L342)
(`let optionalAuthToken = optionalTokenProvider()`), which
[AppDelegate.swift:9-16](../../../GHMenuStars/AppDelegate.swift#L9) wires to the **OAuth token
only**. Without this parameter, a private repo's 4 search calls, commit count and workflow check all
go out on a token that cannot see the repo, 404, and are swallowed into `nil` by the `optional*`
wrappers — producing **blank radar rows with no error**, the precise silent failure the spike was run
to rule out, and a direct failure of success criterion 2. When `optionalAuthToken` is supplied it
must take precedence over the ambient provider; when `nil`, fall back to `optionalTokenProvider()` so
public behaviour is byte-identical.

The `nil` defaults preserve current behaviour and spare ~15 `GitHubClient` construction sites in
`GitHubModelTests` plus the ad-hoc client at
[SettingsView.swift:698](../../../GHMenuStars/SettingsView.swift#L698).

New type `GitHubRepoAccess` owns the resolution rule:

```swift
struct GitHubRepoAccess {
    let client: GitHubClient
    let patProvider: () -> String?

    enum Outcome {
        case fetched(result: GitHubHTTPResult<GitHubRepoResponse>, isPrivate: Bool, token: String?)
        case notModified(token: String?)   // 304: no body, isPrivate carried from the store
    }

    func fetchRepo(owner: String, name: String, etag: String?, knownPrivate: Bool) async throws -> Outcome
}
```

`Outcome` is an **enum, not a struct**, because `request()` *throws* `GitHubError.notModified` on 304
([GitHubClient.swift:570-571](../../../GHMenuStars/GitHub/GitHubClient.swift#L570)) and never
produces a `GitHubHTTPResult` — a struct with a non-optional `result` cannot be constructed on the
304 path, which is the **normal steady state** of every poll
([RepoPollingService.swift:136-137, 143](../../../GHMenuStars/Services/RepoPollingService.swift#L136)).

**Resolution rule:**

1. **Choose the first token.** If the PAT is live (not latched, §2.1) **and** (`knownPrivate` **or**
   the ambient token is `nil`) → try the PAT. Otherwise try the ambient token (OAuth or none).
   *The "ambient is nil" clause is deliberate: a PAT-only user has no OAuth to protect, and falling
   back to anonymous would put public repos on the 60/hr per-IP bucket (see §8).*
2. **404 → retry once with the PAT**, if the PAT is live and was not already tried. Skip this retry
   for repos on the double-404 latch (§2.2). A 404 after both attempts is `.notFoundOrPrivate`.
3. **401 from the PAT attempt → latch the PAT dead (§2.1), then retry once with the ambient token.**
   This fires *regardless of `knownPrivate`*, which is what makes criterion 6 hold: a repo that
   flipped private→public while the PAT was revoked still recovers.
4. **On any 2xx → set `isPrivate` from `result.value.private`, always**, regardless of what was
   stored. This is the only authoritative source; GitHub 404s identically for "does not exist" and
   "you cannot see it", by design, so privacy is unknowable until a fetch **succeeds**.
5. **On 304 → return `.notModified(token:)` carrying the token attached to the 304'd request**, and
   let the caller keep the stored `isPrivate`. Rule 4 cannot apply; there is no body.
6. **Return the winning token** so this repo's releases and radar calls reuse it rather than
   re-deriving from the ambient provider. This is the mechanism that makes `fetchMaintainerRadar`'s
   new parameter actually get a value.

A rate-limited **403** is `GitHubError.rateLimited` ([GitHubClient.swift:577-581](../../../GHMenuStars/GitHub/GitHubClient.swift#L577))
and must propagate untouched — it is neither a 404 nor a 401 and triggers no retry. Retrying under
rate limit would deepen the hole.

#### 2.1 PAT-dead latch

A revoked or expired PAT is dead for **every** repo, not one. The first 401 on a PAT attempt sets an
**in-memory** `patIsDead` latch on `GitHubRepoAccess`; while latched, `patProvider` is treated as
returning nil, so rule 1 goes straight to ambient and each poll costs **one** call, not two.

- Cost is bounded at **one wasted 401 per app launch**, since 401 is deterministic, not transient.
- The latch is **never persisted** — never persist auth state that can be cheaply re-derived.
- It clears on the PAT save/remove action (the same hook §4 uses for the ETag reset) and on relaunch,
  which makes "I fixed the token, restart the app" self-healing rather than a support ticket.
- Latching must **not** short-circuit to the error state: a still-private repo then 404s into §7
  (correct), while a flipped-public repo 200s and recovers (criterion 6).

#### 2.2 Double-404 latch (repo-scoped, distinct from §2.1)

A tracked repo that no longer exists — deleted on GitHub, or a typo tracked while public — 404s on
the ambient attempt *and* the PAT retry, then gets swallowed by `markChecked`
([RepoPollingService.swift:209-211](../../../GHMenuStars/Services/RepoPollingService.swift#L209)) and
repeats forever: ~288 wasted calls/day at 10-minute polling, with no convergence and no user signal.

Keep an **in-memory** set of repo IDs that have failed both ladders. Skip the PAT retry for those
(rule 2), returning to one call per poll — today's cost. Clear it on the PAT save/remove action and
on relaunch. Surface the §7 error state rather than staying silent.

This is a *different* mechanism from §2.1: that one is about a dead token, this one is about a dead
repo. Both are in-memory, both clear on the same hooks.

### 3. Removing the guards, persisting `isPrivate`

The two guards are the load-bearing change:

- [SettingsView.swift:492](../../../GHMenuStars/SettingsView.swift#L492) — add flow
- [RepoPollingService.swift:138](../../../GHMenuStars/Services/RepoPollingService.swift#L138) — every poll

Both are deleted. Each call site instead routes through `GitHubRepoAccess` and records `isPrivate`.

`TrackedRepo.isPrivate: Bool` — decoded with `decodeIfPresent(...) ?? false`, matching the existing
hand-written `init(from:)` style
([TrackedRepo.swift:398](../../../GHMenuStars/Models/TrackedRepo.swift#L398)). Stored repos predate
private support, so `false` is the correct default and migration is free.

Add `isPrivate` to `RepoSnapshot`, and carry it in **both**:
- `TrackedRepoStore.upsertTrackedRepo` ([TrackedRepoStore.swift:42](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L42)) — copies fields member-by-member; a new field not added here is silently dropped on re-add
- `TrackedRepoStore.apply(snapshot:to:)` ([TrackedRepoStore.swift:101](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L101))

### 4. Visibility flips

Driven by rule 4 (`isPrivate` always refreshed from a 2xx):

- **public → private:** stored `isPrivate: false` → ambient → 404 → PAT retry → 200 with
  `private: true` → persist. Recovers automatically.
- **private → public:** stored `isPrivate: true` → PAT → 200 with `private: false` → persist.
- **private → public with a revoked PAT:** PAT → **401** → latch (§2.1) → ambient retry → 200 →
  persist `isPrivate: false`. Recovers. *This is why rule 3 must fire regardless of `knownPrivate` —
  a revoked PAT returns 401, not 404, so the 404 ladder alone would strand this case forever.*
- **private, PAT removed or dead:** 404 after the ladder → §7 error state, last known values kept,
  repo not deleted.

**ETags on flips and token changes.** Stored `etagRepo`/`etagReleases` are minted under a specific
identity. Conditional requests that 304 don't consume rate limit, so a stale-ETag miss costs one
request; trusting a cross-identity ETag costs correctness. Reset at three points:

1. **In `apply(snapshot:)`**, when `snapshot.isPrivate != repo.isPrivate` — clears that one repo.
2. **In the PAT save/remove action** — clears `etagRepo`/`etagReleases` on **all** tracked repos, and
   clears both latches (§2.1, §2.2). Never diff Keychain secrets to detect a change; the action fires
   either way, so "replaced" needs no detection. Requires a new `TrackedRepoStore.clearAllETags()`.
3. **Within the flip poll itself** — when the repo fetch reveals a flip, pass `etag: nil` to the
   *releases* fetch in that same poll ([RepoPollingService.swift:152](../../../GHMenuStars/Services/RepoPollingService.swift#L152)).
   Without this, releases still goes out with the cross-identity ETag *before* the apply-time reset
   fires — the exact hazard this section forbids, inside its own recovery path.

**Known bounded race:** an in-flight poll that started before a PAT save writes
`snapshot.repoETag`/`releasesETag` back in `apply(snapshot:)`
([TrackedRepoStore.swift:117-118](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L117)),
resurrecting an old-identity ETag after the reset. Damage is bounded to one stale conditional request
on the next poll, which then 200s or 304s correctly. Accepted; not worth a generation counter.

Note the existing conditional-request quirk at
[RepoPollingService.swift:136](../../../GHMenuStars/Services/RepoPollingService.swift#L136)
(`repo.lastForks == nil ? nil : repo.etagRepo`) — the reset must not fight it.

### 5. Settings UI

New **Private repositories** section, **behind the hidden flag (default off)**:

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
- Observed during the spike: a user asked to scope a token to one repo produced one granting access
  to **all 31 of their repos**. Assume broad grants are the norm; do not write copy that assumes a
  tightly-scoped token.

**Refactor:** [SettingsView.swift](../../../GHMenuStars/SettingsView.swift) is 911 lines before this
change. Extract the GitHub-auth portion (OAuth sign-in + the new PAT section) into
`Settings/GitHubAuthSettingsView.swift`. Scoped to code phase 1 already edits — not a general cleanup.

### 6. Suppressions for private repos

Gate on `repo.isPrivate`. **Suppress by metric, not by code block** — several of these blocks serve
downloads as well as stars, and a careless `!isPrivate` around the whole block silently kills
download behaviour that private repos are entitled to.

| Behaviour | Location | Rule |
|---|---|---|
| Star notification | [RepoPollingService.swift:283-288](../../../GHMenuStars/Services/RepoPollingService.swift#L283) | Suppress. Already gated on `delta.hasStarIncrease`, which cannot fire for a private repo whose stars aren't fetched — verify rather than assume |
| Star sound | [RepoPollingService.swift:289-297](../../../GHMenuStars/Services/RepoPollingService.swift#L289) | **Careful.** Gated on `starSoundThreshold.isMet(starsDelta:downloadsDelta:downloads:)` — it fires on **download** milestones too. Suppress only the star-driven trigger |
| Celebration animation | [RepoPollingService.swift:298-301](../../../GHMenuStars/Services/RepoPollingService.swift#L298) | **Careful.** `hasCelebrationIncrease` is `starsDelta > 0 \|\| downloadsDelta > 0` ([RepoDelta.swift:13](../../../GHMenuStars/Models/RepoDelta.swift#L13)). Gating the block on `!isPrivate` kills **download** celebrations. Private repos keep the download pulse |
| Star-ask prompt | [RepoPollingService.swift:8-16](../../../GHMenuStars/Services/RepoPollingService.swift#L8) | **No change.** See below |
| Milestone share image | `RepoMilestoneShare.make` ([Formatters.swift](../../../GHMenuStars/Services/Formatters.swift)) | **Privacy.** Guard at the factory, not the menu — see below |
| Star/fork trend submenu | `trendMenu` ([StatusMenuBuilder.swift:124-137](../../../GHMenuStars/StatusMenuBuilder.swift#L124)) | Remove the item for private repos — see below |
| `+N ⭐` on the radar activity row | [StatusMenuBuilder.swift:292](../../../GHMenuStars/StatusMenuBuilder.swift#L292) | Suppress |
| Per-repo menu line | [StatusMenuBuilder.swift:80-118](../../../GHMenuStars/StatusMenuBuilder.swift#L80) | Renders `☆ … ⤓ …` and bold-ranges off star numbers. Private shape: downloads + radar, no star glyph |
| Settings repo row metrics | `RepositoryRow.metricsText` ([SettingsView.swift:801-806](../../../GHMenuStars/SettingsView.swift#L801)) | Renders "Stars … Forks" for every repo. Needs a private shape |
| "public repositories" copy | [StatusMenuBuilder.swift:14](../../../GHMenuStars/StatusMenuBuilder.swift#L14) | Reword |

**Star-ask needs no suppression, and the rationale in revision 1 was wrong.** The prompt does not ask
the user to star the tracked repo — it asks them to star **Stargazer Bar itself**
([RepoPollingService.swift:324](../../../GHMenuStars/Services/RepoPollingService.swift#L324) opens
`AppExternalLinks.gitHubRepository` = `jazzyalex/stargazer-bar`). Its download trigger
(`downloadIncrease >= 20`) remains a legitimate "the app helped you" moment for a private repo, and
the star trigger cannot fire on a repo whose stars are never fetched. **Leave it alone.**

**The share guard belongs in `RepoMilestoneShare.make`, not `canShareMilestone`.**
`canShareMilestone` ([StatusMenuBuilder.swift:222](../../../GHMenuStars/StatusMenuBuilder.swift#L222))
only gates *menu construction*; the action handlers re-derive the share independently
([StatusItemController.swift:264-269](../../../GHMenuStars/StatusItemController.swift#L264)).
Guarding only the menu locks one door and leaves the other open. Guarding the factory covers both.
The guard is *nearly* moot — `make` already returns nil at `currentValue <= 0` — but collaborators
**can** star a private repo, so it insures a real if unlikely leak.

**The trend submenu must be removed, not left empty.** Since the stargazer/fork fetches are skipped,
`trendPoints` stays empty forever and the submenu renders a perpetual "Loading GitHub history…"
([StatusMenuBuilder.swift:720-728](../../../GHMenuStars/StatusMenuBuilder.swift#L720)) — a spinner
that never resolves is worse than no row. The chart is not merely "flat at zero": collaborators can
star and fork private repos, so real data exists; we are choosing not to spend requests on it.

**Skip the stargazer and fork fetches entirely for private repos** — the bulk of the per-poll budget,
counting something we don't display.

### 7. Error handling and copy

[GitHubClient.swift:21](../../../GHMenuStars/GitHub/GitHubClient.swift#L21) currently reads
*"Repository was not found or is private. V1 tracks public repositories only."* — now false. Replace
with copy naming the real causes and pointing at Settings: the repo does not exist, **or** it is
private and no token in Settings can reach it, **or** it is org-owned and the PAT's resource owner is
wrong.

Distinguish a PAT 401 from an OAuth 401: *"Your private-repo token was revoked or expired — update it
in Settings."* A 401 on the PAT path must **not** be reported as a general auth failure and must not
disturb public tracking.

**No expiry state machine in phase 1.** No countdown, no notifications, no proactive warning. The
header is available and the Settings row shows it when parseable; that is the whole feature. FG PATs
can be non-expiring, which removes most of the justification for anything richer.

Missing individual permissions already degrade gracefully via the `optional*` radar wrappers — a PAT
without Actions:Read yields a blank CI row rather than an error.

### 8. Rate limits

All of a user's PATs and OAuth tokens **share one 5,000/hr core bucket** when authenticated, so the
existing single `RateLimitState` remains correct with two tokens in play.

**The exception is the PAT-only user** (adds a PAT, never signs in with OAuth). Their public repos
would poll **anonymously at 60/hr per IP** — a different bucket — and because the global rate-limit
gate pauses *all* polling
([RepoPollingService.swift:71-74, 85](../../../GHMenuStars/Services/RepoPollingService.swift#L71)),
an anonymous 403 on a public repo would starve private repos whose PAT has thousands of requests of
headroom. Rule 1's "ambient is nil → use the PAT" clause exists to prevent exactly this: with no
OAuth token there is nothing to protect, and the PAT is strictly better than anonymous.

Search is a separate 30/min bucket. The radar fires **4** search calls per repo per poll
([GitHubClient.swift:343-364](../../../GHMenuStars/GitHub/GitHubClient.swift#L343)); at the 5-repo
cap ([TrackedRepoStore.swift:10](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L10)) that is
20 per refresh — safe on the 10-minute default poll, but a "Check Now" fired immediately after a
scheduled poll can cross 30/min. The resulting 403 is swallowed by `optional*` into blank rows without
updating `rateLimitState`. **Pre-existing**, not introduced here, but it matters more once the radar is
the whole product for a repo. Recorded; a fix is not in scope.

## Known limitations (deferred, deliberate)

**Commit counts under-report on feature-branch workflows.** `commitCount`
([GitHubClient.swift:458](../../../GHMenuStars/GitHub/GitHubClient.swift#L458)) calls
`/repos/{o}/{r}/commits`, which only covers the **default branch**. Measured on
`jazzyalex/Tennis-Tracker`: `main` had **0** commits in 7 days while `rebuild-foundation` had **100+**.

This is **pre-existing** and already affects public repos — not a regression. Phase 1 displays no
false number: `activityParts` omits the commit row entirely at 0
([StatusMenuBuilder.swift:283-285](../../../GHMenuStars/StatusMenuBuilder.swift#L283)) and labels it
"commits on main" when shown. The real cost is the solo-WIP persona — all work on feature branches,
no PRs or issues — seeing a radar that reads "CI clear · nothing open" on a very much alive repo.
Accurate but incomplete. Tolerable while phase 1 is internal; **fatal in phase 3**, where commits
become the menu bar headline.

Phase 2 fixes it for public and private repos alike: `GET /repos/{o}/{r}/activity?time_period=…`
returns cross-branch push activity in one call (verified HTTP 200, correctly surfaced
`rebuild-foundation`), narrowing the fan-out to *active* refs only — 2 calls for Tennis-Tracker, not
1-per-branch. Results must be **deduped by SHA**: a branch cut from `main` replays main's shared
history, so summing per-branch counts over-counts badly in the common case. `/search/commits` is not
an option; it indexes only the default branch (verified: returned 0 where the true count was 100+).

Phase 1 must **not** advertise commit velocity in UI copy.

## Testing

New:
- `GitHubRepoAccess` resolution: private+PAT → PAT; public+OAuth → ambient; **public with no OAuth +
  PAT → PAT** (§8); 404 → PAT retry → 200 sets `isPrivate: true`; 404 both → `.notFoundOrPrivate`;
  PAT tried at most once per fetch
- **401 on PAT → latch + ambient retry succeeds** (the criterion-6 path); latch makes the next poll
  cost one call; latch clears on PAT save/remove
- **304 → `.notModified` carries the request's token; stored `isPrivate` survives**
- Rate-limited 403 propagates without retry
- Double-404 latch: second poll of a missing repo costs one call, not two
- Flips in all four combinations of `{stored isPrivate} × {PAT live, PAT dead}`
- ETag reset on flip (including releases in the *same* poll), and on PAT save/remove
- `TrackedRepo` decodes legacy JSON with no `isPrivate` → `false`
- `upsertTrackedRepo` and `apply(snapshot:)` round-trip `isPrivate`
- Suppressions: **download** sound/celebration still fire for a private repo (the regression the
  by-block gating would cause); share factory returns nil for private
- Private repo poll issues **no** stargazer/fork request
- `fetchMaintainerRadar` uses the supplied token over the ambient one, and the ambient one when nil
- Keychain: PAT and OAuth stores do not collide

Existing tests — **these must keep passing unchanged**, not be "updated":
- `testPublicRepoFetchDoesNotReadToken` / `testPublicRepoFetchUsesOptionalTokenWhenAvailable`
  ([GitHubModelTests.swift:153, 176](../../../GHMenuStarsTests/GitHubModelTests.swift)) call
  `fetchRepo(owner:name:etag:)` with no token argument, which the `nil` default keeps byte-identical.
  They are **regression guards for success criterion 5**. Revision 1 wrongly listed them as breaking;
  a planner acting on that would have "fixed" the very tests protecting the guarantee.
- `testTrackedReposMigrateFromLegacyBundleDefaults` is in **ServiceLogicTests.swift:472** (not
  GitHubModelTests). Add a no-`isPrivate` fixture.

Expected to need updating: StatusMenu structure tests, where the private-repo line shape shifts items.

## Persistence hazards (noted, not fixed)

1. **Silent wipe on decode failure.** `TrackedRepoStore` decodes with `try?` and falls back to `[]`
   ([TrackedRepoStore.swift:26](../../../GHMenuStars/Persistence/TrackedRepoStore.swift#L26));
   `SettingsStore` falls back to defaults. Any decode bug in a new field destroys all tracked repos or
   all settings with no error surfaced. Pre-existing, but phase 1 is the first edit to these Codables
   since the footgun was loaded — the new-field tests above are the mitigation.
2. **Downgrade hazard (phase 3, recorded here).** `decodeIfPresent` **throws** on a present-but-unknown
   raw value, so running an older build after selecting a future `.selectedRepoCommits` mode fails the
   whole `AppSettings` decode and resets every setting
   ([SettingsStore.swift:168](../../../GHMenuStars/Persistence/SettingsStore.swift#L168)). Not
   triggerable in phase 1, which adds no new enum cases to persisted settings.

## Files touched

| File | Change |
|---|---|
| `Persistence/KeychainTokenStore.swift` | `account` → defaulted **`var`**; PAT service + helpers |
| `GitHub/GitHubClient.swift` | `optionalAuthToken` on `fetchRepo`/`fetchReleases`/**`fetchMaintainerRadar`**; error copy |
| `GitHub/GitHubRepoAccess.swift` | **New.** Resolution rule, 404-retry, PAT-dead latch, double-404 latch |
| `Models/TrackedRepo.swift` | `isPrivate` + decode |
| `Models/RepoSnapshot.swift` | `isPrivate` |
| `Persistence/TrackedRepoStore.swift` | Carry `isPrivate` in upsert + apply; new `clearAllETags()` |
| `Persistence/SettingsStore.swift` | Hidden flag (one bool, default off) |
| `Services/RepoPollingService.swift` | Remove guard; route via `GitHubRepoAccess`; thread winning token to releases + radar; skip stargazers/forks; per-metric suppressions |
| `Services/Formatters.swift` | `RepoMilestoneShare.make` private guard |
| `AppDelegate.swift` | **Construct `GitHubRepoAccess`** with `patProvider`; inject into `RepoPollingService` |
| `PreferencesWindow.swift` | `show(repoStore:settingsStore:gitHubClient:updaterController:)` signature carries the access object |
| `SettingsView.swift` | Remove guard; route via `GitHubRepoAccess`; **`backfillDetails` gates trend fetches and threads the winning token**; `RepositoryRow.metricsText`; shrink via extraction |
| `Settings/GitHubAuthSettingsView.swift` | **New.** OAuth + PAT sections, PAT behind the flag |
| `StatusMenuBuilder.swift` | Private repo line shape; trend item removal; copy at :14 |
| `GHMenuStarsTests/*` | Per Testing above |

`backfillDetails` ([SettingsView.swift:545-584](../../../GHMenuStars/SettingsView.swift#L545)) is the
background path after a successful add. It calls `fetchMaintainerRadar` and the stargazer/fork trend
fetch with no privacy knowledge. Left alone it would fire the star/fork fetches phase 1 skips **and**
fetch the radar on the ambient token — a blank radar for up to a full poll interval, immediately
after the user's first success. It is the add-time half of success criterion 2.

## Success criteria

1. A private repo can be added by `owner/name` with a valid PAT, and polls without error.
2. Its maintainer radar populates PRs, issues, unanswered issues and CI — **at add time via
   `backfillDetails`, not just on the next poll**.
3. It shows no star glyph, fires no star notification/sound/animation, and offers no share image —
   while **download** sounds and celebrations still work.
4. Removing or revoking the PAT degrades to a clear, actionable error — not a crash, not silent
   staleness, not data loss — and costs one call per poll thereafter, not two.
5. Public repo tracking is byte-for-byte unchanged for a user who never adds a PAT, and the existing
   `testPublicRepoFetch*` tests prove it by still passing untouched.
6. A repo that flips visibility in either direction recovers on the next poll with no user action —
   **including when the PAT was revoked before the flip**.
7. With the hidden flag off, a build cut from main is indistinguishable from today for every user.
