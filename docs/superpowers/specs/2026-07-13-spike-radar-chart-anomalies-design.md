# Spike Radar — chart anomalies + richer stats — design

- Date: 2026-07-13
- Status: Draft, awaiting review
- Scope: Stargazer Bar (GHMenuStars) per-repo submenu — trend chart + stats
- Builds on: existing `trendPoints` history and `TrendChartView` in
  [StatusMenuBuilder.swift](../../../GHMenuStars/StatusMenuBuilder.swift)

## Goal

Make the per-repo trend chart *read* the story it already contains: highlight the
days a repo's star growth was abnormally high ("spikes"), and add a couple of
derived stat rows that call out the standout moments. This turns a smooth
cumulative line into something that answers "when did this thing pop, and how
big was it?" at a glance.

Deliberately small and self-contained: a read-only view over data already in
`TrackedRepo.trendPoints`. **No notifications, no menu-bar change, no live
velocity detection, no network calls, no new persisted state, no settings.**
The app's privacy promise ("the only non-GitHub network activity is optional
Sparkle update checking") is untouched because nothing here fetches anything.

## Non-goals (v1)

- Real-time / intra-day velocity spikes (the poll-to-poll "you're spiking now"
  idea) — the chart is daily, so anomalies are per-day historical events.
- Notifications, menu-bar glyphs, sounds, or any alert surface.
- Who-starred-you texture (stargazer avatars / follower weighting).
- Third-party source lookups (Hacker News / Reddit / Lobsters).
- Any toggle or preference. It is always-on passive rendering.

## Data available (no new API calls)

Everything derives from data already stored per repo:

- **Trend history** — `TrackedRepo.trendPoints` (`date`, `stars`, `forks`),
  daily cumulative, covering the full stored history. Daily *increments* are the
  input to anomaly detection.

## Component 1 — anomaly detection (pure function)

New file `GHMenuStars/Services/TrendAnomalyDetector.swift`.

```swift
struct AnomalyDay: Equatable {
    var date: Date            // the day of the spike
    var gain: Int             // stars added that day (daily increment)
    var multipleOfNormal: Double  // gain ÷ robust baseline for that day
}

enum TrendAnomalyDetector {
    static func anomalies(in points: [RepoTrendPoint]) -> [AnomalyDay]
}
```

Algorithm:

1. Sort points by date; compute the per-day star increment
   `gain[i] = stars[i] − stars[i-1]` (skip the first point; clamp negatives to 0
   to absorb any GitHub count corrections).
2. For each day, compute a **robust baseline** over a trailing window
   (default 30 prior daily increments): the **median** and **MAD** (median
   absolute deviation) of that window. MAD, not standard deviation, so a couple
   of big days don't inflate the baseline and mask the rest.
3. A day is anomalous when its increment exceeds the baseline by a robust
   z-score threshold: `gain > median + k · (MAD · 1.4826)` **and** `gain`
   clears a small absolute floor (default ≥ 3) so near-flat repos don't flag
   1-vs-0 wiggle as a spike. `k` default ≈ 3.5.
4. `multipleOfNormal = gain / max(1, median)` for display.
5. Edge cases: series shorter than a minimum window (default ~7 increments) →
   return `[]` (not enough history to call anything anomalous); MAD == 0 (a
   perfectly flat window) → fall back to the absolute floor alone.

Sensitivity note: brainstorm picked the "sensitive" side, but for *historical*
per-day anomalies the robust z-score is what keeps sustained-growth repos from
flagging every day. `k` and the floor are the tuning knobs and live as named
constants for easy adjustment during implementation.

## Component 2 — chart markers

`TrendChartView.draw(_:)` already runs an ordered pass:
`drawGrid → drawHorizontalTicks → drawScale → drawLine(stars) → drawLine(forks)
→ drawReleaseMarker → drawRangeLabels`. Add one pass, `drawAnomalyMarkers`,
immediately after `drawLine(stars)` so the pips sit on top of the star line
(and under nothing that would obscure them).

- For each `AnomalyDay` whose `date` falls inside the visible chart range,
  compute its (x, y) on the **star** line using the same
  date→x / value→y mapping the star line already uses (`chartStart`, `minValue`,
  `maxValue`, `plot` rect).
- Draw a small filled pip (default ~3pt radius) in star-yellow with a thin
  contrasting stroke so it reads on top of the yellow line — visually distinct
  from the existing vertical release marker (which is a line, not a dot).
- Markers are decorative only; no hit-testing / interaction in v1.

Reuse the existing coordinate helpers rather than re-deriving them, so markers
stay pinned to the line if the mapping ever changes.

## Component 3 — richer stats rows

Add derived rows to the repo submenu's stats area (near the trend block, mirroring
the "Last 30 days" row density). Two rows, computed from `trendPoints` +
the anomaly list:

```
Best day      +142 ⭐ on Mar 3
Peak week     +390 ⭐ in 7 days (Mar 1–7)
```

- **Best day** — the single largest daily star increment across stored history:
  its gain and date.
- **Peak week** — the 7-day rolling window with the largest total star gain:
  the total and the window's date range.

Helper lives with the detector (e.g. `TrendAnomalyStats.bestDay(_:)` /
`peakWeek(_:)`) so the menu builder just formats the result. Rows are omitted
when history is too short to compute them (same guard as the detector), so a
freshly added repo shows nothing rather than a misleading "+2 on <today>".

## Wiring

- `StatusMenuBuilder` computes anomalies once per submenu build from
  `repo.trendPoints` and hands the list to (a) the `TrendChartView` it already
  constructs and (b) the new stat rows. `TrendChartView` gains an `anomalies:
  [AnomalyDay]` property alongside its existing `trendPoints` input.
- No changes to `RepoPollingService`, `TrackedRepoStore`, `TrackedRepo`, or any
  persisted model. Nothing is stored or fetched.

## Error handling / robustness

- Insufficient history → detector returns `[]`, stat rows omitted, chart draws
  exactly as today.
- Negative daily increments (count corrections) clamped to 0.
- Markers whose date lands outside the current visible range are skipped.
- All-flat history → no anomalies, no markers, no rows.

## Testing

New `TrendAnomalyDetectorTests` (pure logic, matching the existing
`ServiceLogicTests` / `GitHubModelTests` style):

- Flat series → no anomalies.
- Single sharp spike day → exactly that day flagged, correct `gain` /
  `multipleOfNormal`.
- Sustained steady growth → no anomalies (baseline rises with it).
- Short/sparse series (< min window) → `[]`.
- MAD == 0 window with a jump above the floor → flagged via floor fallback.
- Negative increment clamped, not flagged.
- `bestDay` / `peakWeek`: correct pick on a series with one obvious best day and
  one obvious best 7-day window; omitted on too-short history.

Chart marker geometry is validated by reusing the view's own mapping in a small
test where practical; otherwise verified manually in the running app.

## Files touched

- `GHMenuStars/Services/TrendAnomalyDetector.swift` — new (detector + stat helpers).
- `GHMenuStars/StatusMenuBuilder.swift` — `TrendChartView` gains `anomalies`
  input + `drawAnomalyMarkers`; submenu builder computes anomalies and adds the
  two stat rows.
- `GHMenuStarsTests/TrendAnomalyDetectorTests.swift` — new.
