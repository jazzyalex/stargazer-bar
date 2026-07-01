# "Last 30 days" popup section — design

- Date: 2026-06-28
- Status: Draft, awaiting review
- Scope: Stargazer Bar (GHMenuStars) per-repo submenu
- Builds on: [2026-06-28-release-dynamics-design.md](2026-06-28-release-dynamics-design.md)

## Goal

Add a "Last 30 days" section to the per-repo submenu, directly below the
"Latest release" block, giving a rolling-window view of release adoption and
project momentum. It mirrors the Latest release block's structure and formatting
but drops the per-asset breakdown and adds growth, momentum, and cadence.

## Data available (no new API calls)

Everything reuses data the poll already fetches or stores:

- **Releases list** — each `GitHubRelease` carries `publishedAt` and asset
  `download_count` (decoded in the release-dynamics work).
- **Trend history** — `TrackedRepo.trendPoints` (`date`, `stars`, `forks`) covers
  the full stored history.
- **Totals** — `lastStars`, `lastForks`, `lastDownloads`, and the all-time
  `totalDownloads` computed each poll.

## Layout

Caption plus up to four data rows, same two-column-ish density as Latest release:

```
Last 30 days
3 releases · +142 ⭐ · +12 forks              (releases shipped + current-window growth)
2,480 ↓ · ~83/day · 28% of all                (release-scoped downloads · per-day · share of all-time)
↑ vs prior 30d · +98 ⭐ · +9 forks            (momentum: trend arrow + the prior window's gains)
~1 release / 10 days · avg 827 ↓/release      (cadence + average adoption per release)
```

Rows never repeat a number: row 1 is the *current* window's growth, row 3 is the
*prior* window's growth, and the arrow points ↑/↓/→ based on stars
(current vs prior).

## Metric definitions

Window = fixed **30 days**; `windowStart = now − 30·86400`, `priorStart = now − 60·86400`.

- **releaseCount** — non-draft releases with `publishedAt >= windowStart`.
- **downloads (30d)** — Σ over those releases of Σ `asset.download_count`. This is
  the release-scoped figure agreed in review: downloads *of releases shipped in
  the window*, which slightly undercounts true 30-day downloads (downloads of
  older releases in the period aren't separable from cumulative counts). Reads as
  "recent-release adoption".
- **rate** — `downloads(30d) / 30`, per day.
- **share** — `downloads(30d) / totalDownloads`, whole percent; omitted when total is 0.
- **`valueAt(date)`** — stars/forks of the newest trend point with
  `point.date ≤ date`; `nil` if no such point (history doesn't reach the
  boundary). This single primitive drives every gain below.
- **starsGained / forksGained** — `max(0, current − valueAt(windowStart))`, where
  `current` is `lastStars` / `lastForks`; `nil` when `valueAt(windowStart)` is
  `nil`. Clamped to ≥ 0 (the display never shows a negative "gain") and dropped
  when 0.
- **priorStarsGained / priorForksGained** —
  `max(0, valueAt(windowStart) − valueAt(priorStart))`; `nil` when either is `nil`.
- **trend arrow** — compares stars: `↑` if `starsGained > priorStarsGained`, `↓`
  if `<`, `→` if equal; shown only when both are known.
- **cadence** — `30 / releaseCount` days per release, shown as `~1 release / N days`
  (or `1 release in 30 days` when `releaseCount == 1`).
- **avg downloads/release** — `downloads(30d) / releaseCount`, rounded.

## Conditional rendering

- **Section** shown only when the repo has releases (`latestRelease != nil`) — same
  gating as Latest release. Hidden entirely otherwise.
- **Row 1** — `N releases` shown when `releaseCount > 0` (dropped when 0, so the row
  leads with growth); `+⭐` and `+forks` each dropped when 0 or `nil`.
- **Row 2 (downloads)** — hidden when `downloads(30d) == 0`.
- **Row 3 (momentum)** — shown only when prior-window data is available (history
  reaches `priorStart`) and `starsGained` is known; hidden otherwise.
- **Row 4 (cadence)** — hidden when `releaseCount == 0`.
- Any row whose parts all drop is not added. If every row drops (e.g. brand-new
  repo with one old release and no trend history), only the caption would remain —
  in that case skip the caption too.

## Data and model changes

- **New `RecentReleasesSummary`** (Codable, Equatable):
  `releaseCount: Int`, `downloads: Int`, `totalDownloads: Int`. Computed at poll
  time from the releases list; trend-derived growth is *not* stored here (see
  below). The 30-day window is a fixed constant `ReleaseDynamics.recentWindowDays`,
  not a stored field.
- **Builder** — a `RecentReleasesSummaryBuilder.summary(from:totalDownloads:now:)`
  (mirrors `LatestReleaseSummaryBuilder`), summing releases in the window.
- **`RepoSnapshot`** and **`TrackedRepo`** gain `recentReleases: RecentReleasesSummary?`,
  persisted exactly like `latestRelease` (CodingKey, init param, `decodeIfPresent`,
  `apply(snapshot:)`).
- **Growth + momentum** are computed at menu-render time from `trendPoints`, not
  persisted — consistent with how `starsSinceRelease` already works. Add a
  primitive `ReleaseDynamics.value(in points:, at date:, keyPath:) -> Int?`
  returning the newest trend point at-or-before `date` (a
  `KeyPath<RepoTrendPoint, Int>` selects stars or forks), and express both the
  current and prior gains — and the refactored `starsSinceRelease` — in terms of
  it. `starsSinceRelease` keeps its `max(0, …)` clamp and its existing test.
- **Formatter** — `RecentReleasesLineFormatter` producing the four row strings.
- **Menu** — `addRecentReleasesItems(to:for:)` in `StatusMenuBuilder`, called from
  `trendMenu` right after `addLatestReleaseItems`.

## Poll wiring

In `RepoPollingService.refresh`, alongside the existing
`LatestReleaseSummaryBuilder.summary(...)` call (same `releasesResult.value` and
`downloads`), build `RecentReleasesSummaryBuilder.summary(from:totalDownloads:now:)`
and pass it into the `RepoSnapshot`. On a releases `304 notModified` it is `nil`
(keep the persisted one), matching `latestRelease`.

## Out of scope

- Per-asset / per-release download breakdown (explicitly excluded).
- Downloads momentum (prior-window downloads can't be cleanly isolated under the
  release-scoped model).
- A configurable window — 30 days is fixed.

## Testing

- Builder: `releaseCount` and `downloads` over the window boundary; drafts and
  out-of-window releases excluded; `totalDownloads` passthrough.
- `gainedSince`: current and prior windows; `nil` when history is too short;
  `starsSinceRelease` still passes after the refactor.
- Formatter: each row's string, including the trend arrow (↑/↓/→), cadence
  singular/plural, and share/rate rounding.
- Menu: section hidden with no releases; zero-download row hidden; momentum row
  hidden without prior history; cadence hidden with 0 releases; the `N releases`
  lead dropped when 0.
