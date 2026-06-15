# Changelog

## Unreleased

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
