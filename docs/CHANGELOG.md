# Changelog

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
