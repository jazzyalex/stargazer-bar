# GH Menu Stars

GH Menu Stars is a native macOS menu-bar app for tracking stars on a public GitHub repository.

V1 tracks one public repository, shows stars in the menu-bar counter, and shows latest-100-release download totals in the dropdown. Manual public repository entry does not require credentials. GitHub OAuth device flow is optional and is used only to list public repositories the signed-in user can access.

## Build

```bash
xcodebuild -project GHMenuStars.xcodeproj -scheme GHMenuStars -configuration Debug build
xcodebuild -project GHMenuStars.xcodeproj -scheme GHMenuStars -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

## Privacy

The app stores tracked repository metadata and settings locally in `UserDefaults`. Optional GitHub OAuth tokens are stored in Keychain. The app has no backend and no telemetry.

