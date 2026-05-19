---
name: deploy-stargazer-bar
description: Use when shipping Stargazer Bar from /Users/alexm/Repository/GH-menu-stars, including version readiness checks, Swift/macOS QA, Developer ID signing, notarization, Sparkle appcast publishing, GitHub release assets, GitHub Pages verification, and Homebrew cask updates.
---

# Deploy Stargazer Bar

Use this skill for release/deploy work in `/Users/alexm/Repository/GH-menu-stars`.

## Sources of Truth

- Release docs: `README.md` section "Release & deploy"
- Changelog: `docs/CHANGELOG.md`
- Production deploy: `tools/release/deploy-stargazer-bar.sh`
- Local release-path check: `tools/release/test-release-path.sh`
- Public verification: `tools/release/verify-deployment.sh`
- Notary auth resolver: `tools/release/notary-auth.sh`
- Homebrew updater: `tools/release/update-homebrew-cask.sh`

If these instructions disagree with the scripts, inspect the scripts and follow the current script behavior.

## Workspace Policy

- Run from the user's current checkout: `/Users/alexm/Repository/GH-menu-stars`.
- Do not clone or switch worktrees to deploy.
- Start with `git status --short --branch`; deployment requires a clean `main` synced with `origin/main`.
- Do not commit secrets or generated scratch artifacts. `tools/release/.env` is local credential configuration and should remain untracked.

## Preflight

Run these before publishing:

```bash
git status --short --branch
git fetch --tags origin --quiet
git tag --sort=-version:refname | head -20
gh release view v<VERSION> --repo jazzyalex/stargazer-bar
```

Expected for a new release:

- Working tree clean on `main`
- `HEAD` equals `origin/main`
- Tag `v<VERSION>` does not already exist
- GitHub release `v<VERSION>` does not already exist
- `docs/CHANGELOG.md` contains `## [<VERSION>]`
- `MARKETING_VERSION` in `GHMenuStars.xcodeproj/project.pbxproj` matches `<VERSION>`
- `CURRENT_PROJECT_VERSION` is greater than the previous released build number; Sparkle requires monotonically increasing build numbers
- `gh auth status` succeeds
- A Developer ID Application identity is available
- Notary credentials resolve via `tools/release/notary-auth.sh`
- Sparkle `generate_appcast` exists in Xcode DerivedData, or build once to restore SwiftPM artifacts

## QA Gate

Run automated QA before deploy unless the user explicitly says to skip QA:

```bash
xcodebuild \
  -project GHMenuStars.xcodeproj \
  -scheme GHMenuStars \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

For release-path confidence without publishing:

```bash
VERSION=<VERSION> tools/release/test-release-path.sh
```

In Codex Desktop, Xcode builds and tests may need access to Xcode-managed cache paths such as DerivedData, ModuleCache, SourcePackages, simulator caches, SwiftPM diagnostics, or `~/.cache/clang`. If a first run fails only due to sandbox access, rerun the exact same command with approved Xcode access and report it as a sandbox retry, not a code failure.

## Deploy

Use the production deploy script:

```bash
VERSION=<VERSION> SKIP_CONFIRM=1 tools/release/deploy-stargazer-bar.sh
```

The script builds the Release app, signs with Developer ID, notarizes and staples the app and DMG, creates DMG and Sparkle ZIP assets, generates Sparkle release notes from `docs/CHANGELOG.md`, signs the Sparkle appcast, creates or updates the GitHub release, commits and pushes `docs/appcast.xml`, and updates the Homebrew cask tap when `UPDATE_CASK=1`.

Default production surfaces:

- GitHub repo: `jazzyalex/stargazer-bar`
- GitHub release tag: `v<VERSION>`
- Appcast: `https://jazzyalex.github.io/stargazer-bar/appcast.xml`
- Homebrew cask repo: `jazzyalex/homebrew-stargazer-bar`
- App bundle name: `Stargazer Bar.app`
- Asset basenames: `Stargazer-Bar-<VERSION>.dmg` and `Stargazer-Bar-<VERSION>.zip`

## Verify

After deploy, run:

```bash
tools/release/verify-deployment.sh <VERSION>
```

Verification must cover:

- GitHub release exists
- DMG, DMG SHA, ZIP, and ZIP SHA assets are present
- Public appcast contains `<VERSION>`, signed Sparkle enclosure, GitHub release ZIP URL, and release notes
- DMG and ZIP URLs are reachable
- Homebrew cask version and SHA match the published DMG when `UPDATE_CASK=1`

If GitHub Pages propagation is slow, rerun verification before treating it as a release failure.

## Failure Handling

- If the build number is not greater than the previous release, bump `CURRENT_PROJECT_VERSION` before deploying and commit that change.
- If appcast publication fails, inspect `dist/updates/appcast.xml`, `docs/appcast.xml`, GitHub Pages status, and the release asset URLs.
- If notarization fails, inspect the `notarytool` output and `tools/release/notary-auth.sh`; do not publish unsigned or unstapled artifacts.
- Rollback only after identifying whether the failure is local packaging, GitHub release assets, appcast content, GitHub Pages propagation, or Homebrew cask update.
