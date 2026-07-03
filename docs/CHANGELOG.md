# Changelog

## [0.5.1] - 2026-07-02

### Features
- Added a per-repository **Mute** control in Settings: silence all alerts (notification, sound, celebration, and growth prompt) for a specific repository, independent of its chosen star sound. Star counts and trends keep updating in the background.

### Fixes
- Removing a tracked repository now asks for confirmation before deleting it.

## [0.5.0] - 2026-07-02

### Features
- Track **any public repository**, not just your own — adding a popular repo like `steipete/CodexBar` now populates the full submenu (trend chart, latest release, last-30-days, and maintainer radar), the same as owned repos.
- Adding a repository is now **instant**: it appears immediately with star/download/fork counts and latest-release details, while the slower star/fork trend and maintainer radar backfill in the background instead of blocking the Add button.

### Improvements
- Trend refreshes are now **incremental**: after the one-time history backfill, each poll fetches only the stars and forks added since the last check and merges them, so tracking large, active repositories stays cheap.
- The full stargazer/fork history backfill is page-bounded to respect the GitHub rate limit — full history when signed in, capped when anonymous so a popular repo can't exhaust the unauthenticated quota.
- The activity line in the maintainer radar now reads "N commits on main" for clarity.

## [0.4.0] - 2026-07-01

### Features
- Redesigned per-repository submenu with a **Latest release** block (version, age, downloads, per-day velocity, share of all-time downloads, per-asset sha256/size) and a denser radar layout for release, activity, and CI signals.
- Added a **Last 30 days** section showing the number of new releases, star and fork momentum, download totals and per-day velocity, and comparison against the prior 30-day window.
- Marked the current release date on the star/fork trend chart so the release moment is visible in the history.
- Distinguished release downloads from trend arrows in the menu by using a dedicated `⤓` glyph for downloads.

### Fixes
- Hide the 30-day momentum row when the prior 30-day window has no comparable data so the section does not show a misleading "0" baseline.
- Respect the **Off** activity window setting when computing the last-30-days summary and cap long asset labels so the submenu no longer widens unpredictably.

## [0.3.1] - 2026-06-14

### Fixes
- Use the saved GitHub token for background public repository polling so star counts, release downloads, trends, and maintainer radar use the higher authenticated API quota when connected.
- Retry rate-limited refreshes at GitHub's reset time and clear expired rate-limit state before polling again.

## [0.3] - 2026-06-14

### Features
- Added a maintainer radar menu for GitHub workflow alerts and repository activity signals.

### Improvements
- Flattened and polished the radar menu so active alerts and tracked repositories are easier to scan from the menu bar.
- Improved milestone sharing polish and refreshed the public screenshots.

### Fixes
- Fixed radar API request handling and stale workflow radar alerts.
- Fixed milestone share metric selection.

## [0.2.3] - 2026-06-13

### Features
- Added a one-time growth prompt after a tracked repo gains its first detected star or at least 20 release downloads in one refresh, with actions to star Stargazer Bar, defer, or stop asking.
- Added per-repo milestone sharing from the menu: copy star/download text, copy a generated square milestone image, or open an X compose window with the image copied to the pasteboard.

### Improvements
- Added subtle About/README copy explaining that GitHub stars help other maintainers discover the app.
- Added the GitHub star CTA to Sparkle and GitHub release notes.

## [0.2.2] - 2026-06-05

### Fixes
- Clear stale Stargazer Bar entries from the Dock recent-apps list when the Dock icon is hidden.
- Rename the setting to **Hide Dock icon** so the toggle state directly matches the behavior.

## [0.2.1] - 2026-06-04

### Fixes
- Launch Stargazer Bar as a menu bar agent so it does not appear as a normal Dock app.

## [0.2] - 2026-05-29

### Features
- Added support for tracking multiple public repositories from the menu bar.
- Added per-repository star sounds for distinct update cues.

### Improvements
- Simplified the status menu refresh action to a single **Check Now** item.
- Refreshed public screenshots and copy for the Stargazer Bar rename and multi-repo workflow.

## [0.1.2] - 2026-05-22

### Fixes
- Started GitHub device authorization automatically when browsing repositories needs a token.
- Improved user-facing GitHub error messages for server, transport, and unexpected response failures.

## [0.1.1] - 2026-05-19

### Changes
- Renamed from GH Menu Stars to **Stargazer Bar**. New bundle identifier (`com.jazzyalex.StargazerBar`) and new appcast URL (`https://jazzyalex.github.io/stargazer-bar/appcast.xml`).
- Reorganized Settings into tabs so the window fits without scrolling.

## [0.1.0] - 2026-05-16

### Features
- Initial menu-bar app for tracking GitHub repository stars and latest release downloads.
- Optional GitHub OAuth device flow for browsing public repositories available to the signed-in user.
- Sparkle update support with automatic checks and automatic downloads enabled by default.

### Improvements
- Local-only storage for tracked repository metadata and settings.
