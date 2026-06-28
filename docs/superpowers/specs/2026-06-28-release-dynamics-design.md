# Release dynamics in the per-repo popup — design

- Date: 2026-06-28
- Status: Draft, awaiting review
- Scope: Stargazer Bar (GHMenuStars) menu-bar app

## Goal

After a maintainer ships a release, the per-repo submenu should answer three
questions at a glance, without opening GitHub:

1. **Is it being adopted?** — downloads on the newest release, daily rate, share of total, asset split.
2. **Did it break anything?** — issues opened since the release shipped.
3. **Did it move growth?** — stars gained since the release.

This is delivered as an inline redesign of the section below the trend chart,
not a new window or nested submenu.

## Background

The per-repo submenu today (built in `StatusMenuBuilder.trendMenu` →
`addMaintainerRadarItems`) shows: the star/fork trend chart, then the maintainer
radar (CI status, new PRs/issues in a configurable window, recent commits, open
PRs, issues needing first reply, Discussions, "Updated …"), then Share Milestone
and Open Repo.

Two relevant facts make this feature cheap:

- The app **already fetches the releases list** (up to 100 releases) to compute
  total downloads via `ReleaseDownloadAggregator`. The `GitHubRelease` model
  currently decodes **only** `assets` (name + `download_count`) and discards tag,
  name, and dates.
- Star history is already stored per repo as `trendPoints`, so "stars since a
  date" needs no new fetch.

So nearly all of this reuses data already on hand. **No new API calls, no backend.**

## Design decisions

- **Placement: inline.** A "Latest release" block sits directly under the chart,
  above the radar. (Considered and rejected: a nested `Latest Release ▸` submenu —
  hides the new signal one hover too deep.)
- **Density redesign of the whole section below the chart**, driven by these rules:
  1. **Hide healthy/zero rows.** No `0 new PRs`, `0 open PRs`, `0 issues need
     first reply`. When nothing is open, collapse to one muted footer line.
     A row appears only when it carries a number worth acting on.
  2. **State the activity window once** as a caption, not repeated per row.
  3. **Pack related metrics** onto one line with `·` separators.
  4. **Collapse the footer**: Discussions + Open on GitHub share a row; the
     "Updated …" timestamp folds into the healthy-state line.
- **Window anchoring.** When the repo has a *fresh* release — published within
  `releaseFreshnessWindow` (a fixed constant, default 14 days) — the activity
  counts anchor to the release publish date and the caption becomes `Since <tag>`.
  Otherwise the radar keeps the configured activity window (`Last <window>`). This
  preserves the recent-activity signal for repos whose last release is old, while
  giving the "since I shipped" framing for the two weeks that matter most. No new
  user setting; the horizon is a constant.
- **Graceful absence.** Repos with no releases hide the entire "Latest release"
  block and the chart marker; the radar behaves exactly as today (minus the
  now-suppressed zero rows).

## Feature detail

### Latest release block

Rendered under the chart when the repo has at least one published release:

```
Latest release                         (muted caption)
<tag> · <age>                          (tag emphasized, e.g. "v0.3.1 · 2d ago")
<downloads> ↓ · ~<rate>/day · <share>% of all
<asset1> <n1> · <asset2> <n2>          (top assets; omit when a single asset)
```

- **Latest release selection**: the newest non-draft release by `published_at`,
  computed locally over the already-fetched list (the same list used for total
  downloads). Prereleases are included but flagged with a trailing `· pre`. The
  list holds the 100 most recent releases, which in practice always contains the
  newest published one.
- **downloads**: sum of the latest release's asset `download_count`s.
- **rate (velocity)**: `downloads / max(1, daysSincePublish)` — a lifetime
  average for that release (see "v1 scope").
- **share**: `downloads / totalDownloads`, rounded to a whole percent; guarded
  against divide-by-zero (omit when total is 0).
- **asset split**: the top 2 assets by download count as `<label> <count>` joined
  by `·`, omitted when the release has a single asset. `<label>` is the asset name
  with the common prefix shared by all of the release's asset names stripped
  (typically the `<repo>-<version>-` portion); if a label is still longer than
  ~16 chars, fall back to its file extension / platform token (e.g. `arm64.dmg`).
  Keeps the row inside the menu width.

### Chart marker

A `▼` marker on the existing `RepoTrendView` at the x-position matching the
release `published_at`, giving visual context for the stars-since delta. Drawn
only when a latest release exists and its publish date falls within the chart's
visible range.

### Activity line — `Since <tag>` (regressions + growth)

Replaces the separate windowed radar rows (new PRs, new issues, commits) with one
packed line:

```
Since <tag>                            (muted caption — or "Last <window>")
<commits> commits · <newPRs> new PRs · <newIssues> new issues · +<starsSince> ⭐
```

- Only non-zero parts are rendered; if every part is zero the line is omitted
  (its content would be "nothing happened", which the design suppresses).
- **commits / newPRs / newIssues**: the three already-windowed maintainer-radar
  metrics. When the repo has a fresh release they are fetched with the release
  `published_at` as the `since` bound and the caption reads `Since <tag>`;
  otherwise they use the configured activity window and the caption reads
  `Last <window>` (e.g. `Last 24h`).
- **starsSince**: `currentStars − stars at-or-before published_at`, read from
  `trendPoints` (nearest point with date ≤ publish date). Omitted when history
  doesn't reach back to the publish date.

### Remaining radar rows + footer

Unchanged in meaning, redesigned for density:

```
<open PRs> open PRs · <unanswered> need first reply   (each part shown only when > 0; row omitted when both 0)
<CI clear> · <nothing open> · updated <time>          (muted; assembled from conditional segments)
Open Discussions · Open on GitHub
Share Milestone ▸
```

- The open-state row lists only the metrics that are `> 0`; it is omitted when
  both are zero.
- The muted footer line always ends with `updated <time>` and prepends only the
  segments that hold: `CI clear` only when CI passed, `nothing open` only when
  both open metrics are zero. A failing build keeps its own prominent
  `CI failing: <name>` row instead and contributes no `CI clear` segment — so a
  repo with a failing build and open PRs shows just `updated <time>`.

## Data and model changes

- **`GitHubRelease`** (`GitHubClient.swift`): decode `tag_name`, `name`,
  `published_at`, `draft`, `prerelease` in addition to `assets`. Existing
  `ReleaseDownloadAggregator` is unaffected.
- **New value type `LatestReleaseSummary`** (Codable, Equatable):
  `tag: String`, `name: String?`, `publishedAt: Date`, `isPrerelease: Bool`,
  `downloads: Int`, `assetBreakdown: [(name: String, count: Int)]`. Derived from
  the releases list plus the already-computed `totalDownloads`.
- **`RepoSnapshot`**: add `latestRelease: LatestReleaseSummary?`.
- **`TrackedRepo`**: add a persisted `latestRelease: LatestReleaseSummary?`
  (mirroring how `maintainerRadar` is stored — new CodingKey, init param,
  `decodeIfPresent`).
- **Radar fetch**: accept an optional `releaseAnchor` (the latest fresh release's
  `publishedAt`). When present, use it as the `since` bound instead of the
  configured window and surface a flag so the menu labels the line `Since <tag>`.
  This creates a fetch-ordering dependency — releases must be decoded before the
  radar query within a poll so the anchor is available; the polling sequence must
  reflect that.

## v1 scope (deliberately bounded)

- Velocity is a **lifetime average** (`download_count` is cumulative). A true
  recent-rate curve needs per-release download snapshots over time — **phase 2**.
- **Phase 2 also**: same-age comparison vs the previous release
  (`v0.3.1 at day 2` vs `v0.3.0 at day 2`), which likewise needs historical
  per-release tracking.

## Out of scope

- Per-release reactions, release author, draft tracking.
- Platform inference / per-asset icons.
- Any new network endpoint or backend.

## Testing

Mirror the existing menu/model test style (`ServiceLogicTests`,
`GitHubModelTests`):

- Decode of the expanded `GitHubRelease` fields.
- `LatestReleaseSummary` derivation: latest selection ignores drafts, includes
  and flags prereleases; downloads, share, and velocity math; divide-by-zero
  guard; asset-split ordering and truncation.
- Stars-since-release from `trendPoints`, including the "history too short →
  omit" case.
- Window re-anchoring: `Since <tag>` label and release-anchored `since` bound
  when the latest release is fresh (within `releaseFreshnessWindow`); configured
  window and `Last <window>` label otherwise.
- Conditional rendering: zero rows suppressed; the whole block hidden for a repo
  with no releases.

## Risks / notes

- "Latest" derived from the fetched list rather than the `/releases/latest`
  endpoint, to avoid an extra call; equivalent because releases are returned
  newest-first and drafts are filtered locally.
- Manually-tracked repos with no releases must degrade cleanly — covered by the
  graceful-absence rule and a dedicated test.
