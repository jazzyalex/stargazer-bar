<div align="center">

<img src="docs/assets/og-banner.png" alt="Stargazer Bar — GitHub stars, trends, and maintainer radar in your menu bar" width="780">

<h1>Stargazer Bar</h1>

<p>
  <strong>GitHub stars in your macOS menu bar.</strong><br>
  A tiny native app for watching your repositories — public and private —<br>
  release downloads without keeping GitHub open.
</p>

<p>
  <a href="https://github.com/jazzyalex/stargazer-bar/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/jazzyalex/stargazer-bar?label=release&color=0071e3&style=flat-square"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-BSD%203--Clause-6e6e73?style=flat-square"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS-1d1d1f?style=flat-square">
  <a href="https://github.com/jazzyalex/homebrew-stargazer-bar"><img alt="Homebrew" src="https://img.shields.io/badge/homebrew-cask-fbb040?style=flat-square"></a>
</p>

<p>
  <a href="https://github.com/jazzyalex/stargazer-bar/releases/latest"><b>Download</b></a>
  &nbsp;·&nbsp;
  <a href="https://jazzyalex.github.io/stargazer-bar/"><b>Website</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/jazzyalex/stargazer-bar/issues"><b>Issues</b></a>
</p>

</div>

---

Stargazer Bar is an open-source macOS GitHub stars menu bar app for maintainers who want lightweight launch or release telemetry. Public repositories are measured by stars; private ones — which have none — are measured by what needs you: a failing build, an unanswered issue, a new pull request. It works as a small GitHub release download counter too: the headline number stays in the menu bar, detail lives in the dropdown, and the app reads GitHub directly without a backend.

## Install

**Homebrew** *(recommended)*

```bash
brew install --cask jazzyalex/stargazer-bar/stargazer-bar
```

**Direct download**

Grab the signed, notarized Apple silicon DMG from the [latest release](https://github.com/jazzyalex/stargazer-bar/releases/latest).

## Features

- ⭐ &nbsp;Live star counts for multiple public repos in your menu bar — no browser tab required
- 🔒 &nbsp;Private repos too: track what needs you, with a 30-day commit chart counted across every branch
- 📦 &nbsp;Release download totals from GitHub's latest releases API page (up to 100 releases)
- 📈 &nbsp;Per-repo star and fork trend charts directly in the menu
- 🧭 &nbsp;Maintainer radar for CI status, recent commits, new PRs/issues, and unanswered issues
- 🖼️ &nbsp;Copy milestone text or a square share image when a repo passes a rounded download/star mark
- 🔔 &nbsp;Per-repository star sounds, so each tracked project can have its own update cue
- 🔑 &nbsp;Track any public repo without a GitHub account; sign-in powers the repo picker, and a read-only fine-grained token unlocks private repos
- 🔄 &nbsp;Sparkle auto-updates, EdDSA-signed and notarized
- 🔒 &nbsp;Private by default — no backend, no telemetry, Keychain-stored tokens
- 🪶 &nbsp;Native Apple silicon app, designed to stay out of the way

<div align="center">
  <img src="docs/assets/hero-stage.png" alt="Stargazer Bar menu showing multiple tracked repositories, a star/fork trend graph, and maintainer radar rows" width="560">
</div>

<div align="center">
  <sub><b>Track any public repository — not just your own.</b> Full trend, releases, and maintainer radar for <code>steipete/CodexBar</code>:</sub>
  <br>
  <a href="docs/assets/track-any-public-repo.png"><img src="docs/assets/track-any-public-repo.png" alt="Stargazer Bar submenu for a non-owned public repository (steipete/CodexBar) showing the all-time trend, latest release, last 30 days, and maintainer radar" width="260"></a>
</div>

## Stargazers

Open the app’s menu, select a tracked repository, and choose **Stargazers…**. **Current** shows a scrollable list and loads public names and bios as accounts come into view. Select an account for details and any profile links they published on GitHub, or use **Load visible star totals** to compare stars received across the accounts in view. The summaries use GitHub data and arithmetic.

**Disappeared** shows each account’s last-known handle and the interval from when it was last seen to the first complete check that found it missing. Unstarring, account deletion, suspension, or visibility changes can explain a disappearance. A star removed and restored between checks leaves no record.

Checks run on launch, through **Check Now**, and on the configured 10-minute, hourly, or daily schedule while the app is running. The first successful check establishes a baseline. GitHub restricts identity lists to repository admins and collaborators. An incomplete check keeps the last valid snapshot and its history. [GitHub stargazer access policy](https://github.blog/changelog/2026-09-04-new-api-endpoint-provides-privacy-safe-star-history-data/)

If two walks of the stargazer list agree but differ from GitHub’s reported star count, **Current** shows both counts. Agent Sessions requires additional checks before saving any snapshot. The GraphQL list must contain the same account IDs as REST, and the complete star-history total must match the list size. A passing cross-check establishes a baseline for visible accounts. Later checks repeat the verification before recording changes. If verification fails, the existing baseline and history remain available.

## Privacy

The app stores tracked repository metadata and settings locally in `UserDefaults`. Stargazer snapshots and up to 90 days of disappearances are stored in local Application Support. Author profiles are cached in memory. GitHub credentials are stored in Keychain. There is **no backend and no telemetry**. The app fetches data from GitHub, and optional Sparkle update checking uses the release feed. Profile links open in your browser when clicked.

## Build from source

```bash
xcodebuild -project GHMenuStars.xcodeproj -scheme GHMenuStars -configuration Debug build
xcodebuild -project GHMenuStars.xcodeproj -scheme GHMenuStars -configuration Debug \
  -destination 'platform=macOS,arch=arm64' test
```

The **Connect GitHub** feature uses GitHub's OAuth device flow. Manual repository tracking works without credentials; the signed-in repository picker requires a GitHub OAuth app client id.

For local builds, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `GHMENUSTARS_GITHUB_OAUTH_CLIENT_ID`. The local config file is gitignored. You can also pass `GHMENUSTARS_GITHUB_OAUTH_CLIENT_ID=...` to `xcodebuild`, or launch with `GH_MENU_STARS_GITHUB_CLIENT_ID=...` for one-off debugging.

<details>
<summary><b>Release &amp; deploy</b></summary>

<br>

Stargazer Bar uses Sparkle 2 for signed automatic updates. The production appcast is published at:

```
https://jazzyalex.github.io/stargazer-bar/appcast.xml
```

The release helper builds the Release app, signs with Developer ID, notarizes and staples the app and DMG, generates a Sparkle EdDSA-signed appcast for the zipped archive (release notes from `docs/CHANGELOG.md`), creates or updates the GitHub release, commits the appcast, verifies the public release, and updates the Homebrew cask tap:

```bash
VERSION=0.2 tools/release/deploy-stargazer-bar.sh
tools/release/verify-deployment.sh 0.2
```

The script expects `gh` authentication, a Developer ID Application certificate, notary credentials, and the Sparkle EdDSA private key in Keychain. `tools/release/.env` may provide `TEAM_ID`, `DEV_ID_APP`, `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER`, or `SPARKLE_ED_KEY_FILE`.

Homebrew tap settings:

```bash
UPDATE_CASK=1
CASK_REPO=jazzyalex/homebrew-stargazer-bar
```

To test the full local release path without publishing or modifying `docs/appcast.xml`:

```bash
VERSION=0.2 tools/release/test-release-path.sh
```

This builds the Release app, signs with Developer ID, packages a DMG and Sparkle ZIP, checksums them, renders release notes, and generates a signed Sparkle appcast in a new `dist/release-path-test.*` directory. It notarizes when credentials are configured. Set `REQUIRE_NOTARY=1` to fail the test if notarization is unavailable.

</details>

## License

[BSD 3-Clause](LICENSE) · See [Third-Party Notices](ThirdPartyNotices.md)

<div align="center">
  <sub>Made with care for people who like their tools small and quiet. If it helps, a GitHub star helps others find it.</sub>
</div>
