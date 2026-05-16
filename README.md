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

## Privacy

The app stores tracked repository metadata and settings locally in `UserDefaults`. Optional GitHub OAuth tokens are stored in Keychain. The app has no backend and no telemetry.
