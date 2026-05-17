# GH Menu Stars

GH Menu Stars is a native macOS menu-bar app for tracking stars on a public GitHub repository.

V1 tracks one public repository, shows stars in the menu-bar counter, and shows latest-100-release download totals in the dropdown. Manual public repository entry does not require credentials. GitHub OAuth device flow is optional and is used only to list public repositories the signed-in user can access.

## Build

```bash
xcodebuild -project GHMenuStars.xcodeproj -scheme GHMenuStars -configuration Debug build
xcodebuild -project GHMenuStars.xcodeproj -scheme GHMenuStars -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

`Connect GitHub` uses GitHub's OAuth device flow. Manual repository tracking works without credentials, but the signed-in repository picker requires a registered GitHub OAuth app client id.

For local builds, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `GHMENUSTARS_GITHUB_OAUTH_CLIENT_ID`. The local config file is ignored by git. You can also pass `GHMENUSTARS_GITHUB_OAUTH_CLIENT_ID=...` to `xcodebuild`, or launch with `GH_MENU_STARS_GITHUB_CLIENT_ID=...` for one-off debugging.

## Release

GH Menu Stars uses Sparkle 2 for signed automatic updates. The production appcast is published from `docs/appcast.xml` to:

```text
https://jazzyalex.github.io/GH-menu-stars/appcast.xml
```

The release helper builds the Release app, signs with Developer ID, notarizes and staples the DMG, generates a Sparkle EdDSA-signed appcast for the zipped app archive with release notes from `docs/CHANGELOG.md`, commits the appcast, and creates or updates the GitHub release:

```bash
VERSION=0.1.0 tools/release/deploy-gh-menu-stars.sh
tools/release/verify-deployment.sh 0.1.0
```

The script expects `gh` authentication, a Developer ID Application certificate, notary credentials, and the Sparkle EdDSA private key in Keychain. `tools/release/.env` may provide `TEAM_ID`, `DEV_ID_APP`, `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER`, or `SPARKLE_ED_KEY_FILE`.

To test the full local release path without publishing or modifying `docs/appcast.xml`:

```bash
VERSION=0.1.0 tools/release/test-release-path.sh
```

This builds the Release app, signs with Developer ID, packages a DMG and Sparkle ZIP, checksums them, renders release notes, and generates a signed Sparkle appcast under `dist/release-path-test`. It notarizes when credentials are configured; set `REQUIRE_NOTARY=1` to fail the test if notarization is unavailable.

## Privacy

The app stores tracked repository metadata and settings locally in `UserDefaults`. Optional GitHub OAuth tokens are stored in Keychain. The app has no backend and no telemetry. The only non-GitHub network activity is optional Sparkle update checking when updates are enabled.
