# Stargazer Bar 0.2 Roadmap

Goal: make Stargazer Bar support multiple public repositories while keeping the app tiny, fun, and understandable.

Non-goals for 0.2:

- No required GitHub login.
- No private repository support beyond existing optional auth behavior.
- No issues, pull requests, CI, local git state, or contribution dashboards.
- No SQLite/cache rewrite.
- No heavy analytics window.

## Theme

0.2 should feel like a small public GitHub momentum toy:

- Track several repos.
- Choose what the menu bar shows.
- Hear a funny sound when stars or downloads move.
- Open the menu for the small scoreboard.

## Feature 1: Multi-Repo Tracking

Current state:

- `TrackedRepoStore` stores `[TrackedRepo]`, but `setTrackedRepo(_:)` replaces the array with a single repo.
- `StatusLabelView`, `StatusMenuBuilder`, and settings all read `trackedRepos.first`.
- `TrackedRepo` already contains per-repo stars, downloads, timestamps, ETags, and notification fields.

0.2 implementation direction:

- Replace `setTrackedRepo(_:)` with add/update behavior.
- Keep stable `TrackedRepo.id` when updating an existing `owner/name`.
- Add remove and reorder operations.
- Preserve per-repo ETags, timestamps, and notification state.
- Keep persisted storage in `UserDefaults` for now.

Suggested store API:

```swift
func upsertTrackedRepo(_ repo: TrackedRepo)
func removeTrackedRepo(id: UUID)
func moveTrackedRepos(fromOffsets: IndexSet, toOffset: Int)
func setMenuBarRepo(id: UUID?)
```

## Feature 2: Menu-Bar Display Mode

This is the main product question for multi-repo support.

Recommended 0.2 answer:

- Show one compact counter in the menu bar.
- Add a setting for what that counter means.

Display modes:

- `Selected repo stars`: current behavior, but user can choose the repo.
- `Selected repo downloads`: same compact slot, package/download icon.
- `Total stars`: sum stars across tracked repos.
- `Total downloads`: sum release downloads across tracked repos.
- `Rotating repos`: periodically cycle through tracked repos, showing repo initials/name hint plus stars.

Defer these until later:

- Multiple independent status items.
- Wide menu-bar text listing several repos at once.
- Dashboard/card window.

Why: multiple menu-bar items can become noisy fast, and a wide combined label fights the tiny-counter identity.

## Feature 3: Scoreboard Menu

The dropdown should become the multi-repo surface.

Proposed menu structure:

```text
Stargazer Bar

Stars  stargazer-bar             128   +4
Dl     stargazer-bar downloads   892   +21

Stars  RepoBar                 2.0k   +33
Dl     RepoBar downloads       4.8k   +120

Check All Now
Open Selected on GitHub

Display Mode
  [x] Selected repo stars
    Selected repo downloads
    Total stars
    Total downloads
    Rotate repos

Sounds
  [x] Enabled
  Preview Sound

Settings...
Quit
```

For repo rows:

- Keep the row readable at menu width.
- Use compact formatted numbers.
- Show positive deltas only.
- Use disabled title rows for metrics and action rows for repo operations.
- A repo submenu can hold `Open`, `Show in menu bar`, `Check now`, and `Remove`.

## Feature 4: Settings Update

Settings should move from a single current-repo panel to a small list editor.

Minimal 0.2 layout:

- Header.
- `Repositories` group:
  - list of tracked repos
  - stars/downloads snapshot per row
  - selected-menu-bar marker
  - remove button
  - add text field
- `Menu Bar` group:
  - display mode picker
  - selected repo picker when needed
  - rotate interval when needed
- `Refresh` group unchanged.
- `Celebrations` group for notifications, animation, and sounds.
- `GitHub Account` remains optional and clearly scoped to picking public repos.

Avoid a large repository browser. The app only needs a small tracked list.

## Feature 5: Funny Sounds

Current state:

- `SoundService` plays the built-in `Glass` sound.
- Settings already include `Play sound on star increases`.

0.2 direction:

- Add a sound picker.
- Add a preview button.
- Support separate sound events:
  - star increase
  - download increase
  - milestone crossed
- Keep mute global.

Sound options should be silly but not obnoxious:

- `Glass` - current default
- `Pop`
- `Ping`
- `Funk`
- `Hero`
- `Coin`
- `Applause Lite`
- `Silent`

Implementation options:

- Start with bundled short `.aiff` or `.caf` files under app resources.
- Keep each clip under roughly one second.
- Use `NSSound` for playback.
- Store the selected sound name in settings.

Milestones worth celebrating:

- Stars cross a round number: 10, 50, 100, 500, 1k, 5k, 10k.
- Downloads cross a round number: 100, 1k, 10k, 100k.
- Any single refresh adds more than a configured threshold.

For 0.2, make milestone sounds automatic but quiet: reuse the selected sound, maybe with two quick plays only if that does not feel annoying in QA.

## Feature 6: Delta Handling Per Repo

Current state:

- `TrackedRepoStore.lastDelta` is global.

0.2 needs per-repo deltas so the menu can show which repo moved.

Recommended model:

- Add `lastStarsDelta` and `lastDownloadsDelta` to `TrackedRepo`, or
- Store `[UUID: RepoDelta]` in the store and persist only if useful.

Prefer adding fields to `TrackedRepo` for 0.2. It keeps the menu simple after app restart.

## Feature 7: Polling Behavior

Current state likely refreshes the first tracked repo.

0.2 behavior:

- Refresh repos sequentially, not in parallel, to respect unauthenticated rate limits.
- Reuse existing ETags per repo.
- `Check All Now` refreshes all repos.
- `Check Now` on a repo refreshes only that repo.
- If rate-limited, keep old values and show reset time.

Recommended initial cap:

- Soft cap tracked repos at 10 for unauthenticated use.
- Show a gentle warning above 10 that refreshes may be slower or rate-limited.

## Suggested Milestones

### 0.2.0-alpha

- Store supports multiple repos.
- Settings can add/remove repos.
- Polling refreshes all tracked repos.
- Menu shows a simple scoreboard.

### 0.2.0-beta

- Menu-bar display mode setting.
- Selected repo picker.
- Total stars/downloads modes.
- Per-repo delta display.

### 0.2.0

- Sound picker and preview.
- Star/download/milestone celebration logic.
- Polished empty/error/rate-limit states.
- README and website updated with multi-repo screenshots.

## Validation Plan

- Unit tests:
  - upsert preserves existing repo identity and ETags
  - remove/reorder behavior
  - aggregate display values
  - per-repo deltas
  - milestone crossing detection
- Manual QA:
  - add 3 public repos without signing in
  - restart app and confirm all values persist
  - switch menu-bar modes
  - force refresh and confirm stale values remain visible
  - preview every sound
  - verify the menu stays readable with 10 repos

If any QA script changes macOS Appearance, restore Appearance to `System` at the end.
