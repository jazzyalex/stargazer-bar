---
name: deploy
description: Use when shipping a release of Stargazer Bar (GHMenuStars) — running QA, bumping the version, updating CHANGELOG, then building, signing, notarizing, publishing the GitHub release, updating the Sparkle appcast, and updating the Homebrew cask.
---

# Deployment Skill (Stargazer Bar)

Agent-facing entrypoint for shipping a release. The single source of truth for
the mechanics is the deploy script itself:

- Unified script: `tools/release/deploy-stargazer-bar.sh` (run `--help` for env/args)
- Post-deploy check: `tools/release/verify-deployment.sh`
- Homebrew cask updater: `tools/release/update-homebrew-cask.sh` (invoked automatically)
- Sparkle notes generator: `tools/release/sparkle_release_notes.py` (invoked automatically)

If anything here disagrees with the script, the script wins — read it.

## Workspace Policy (Hard Rule)

- Always deploy from the user's current local checkout of this repo.
- Never clone to a temp dir or switch to an alternate worktree as a workaround.
- The script refuses to run on a dirty tree, off `main`, or when local `main` is
  not in sync with `origin/main`. So the tree must be committed and pushed first.

## QA Gate (Mandatory — Run Automatically, Do Not Ask)

Always run QA automatically before bumping or releasing. Never ask whether to run
it — just run it. Only skip if the user explicitly says "skip QA".

1. **Scope** — `git log --oneline --decorate -n 30` and
   `git diff --name-only $(git describe --tags --abbrev=0)..HEAD`; note high-risk areas.
2. **Build + test** (use a build-only derived-data path, never one later used to
   `open` the app):
   ```bash
   xcodebuild -project GHMenuStars.xcodeproj -scheme GHMenuStars \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .deriveddata-test test
   ```
3. **Warnings sweep** — flag any new actionable warnings in the build output.
4. On **GO** (build + tests green) proceed straight to the version bump and docs —
   do not pause. On **NO-GO**, surface the specific failure and ask for a GO/NO-GO
   decision. Do not bump or release on a failing gate.

## Versioning

- Patch releases are `X.Y.Z`. Never ship a `.0` from this skill unless the user
  explicitly asks for a minor/major.
- **There is no bump tool** — edit the version by hand in
  `GHMenuStars.xcodeproj/project.pbxproj`. It appears in **both** the Debug and
  Release `XCBuildConfiguration` blocks; change both:
  - `MARKETING_VERSION = <old>` → the new `X.Y.Z`
  - `CURRENT_PROJECT_VERSION = <n>` → `<n+1>` (monotonic integer build number)
- `Info.plist` reads `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, so no
  other file needs the version.
- The script does not bump anything; it reads `MARKETING_VERSION` from the project
  (or an explicit `VERSION=` env) and hard-fails later steps if they disagree.

## CHANGELOG (Required — Script Hard-Checks It)

`tools/release/deploy-stargazer-bar.sh` aborts unless `docs/CHANGELOG.md` has a
`## [$VERSION]` section. Add one at the top, matching the existing format:

```markdown
## [0.5.2] - YYYY-MM-DD

### Features
- User-facing sentence describing the headline change.

### Fixes
- ...
```

Write it as **user-facing product copy**, not commit history. Lead with the
change users care about. Do not list internal cleanup or pre-release
stabilization as "Fixes" for behavior users never received. The Sparkle notes and
the GitHub release notes are both generated from this section, so it is the copy
users actually see.

## Public Copy (Usually No Edits Needed)

Unlike some sibling projects, `README.md` and `docs/index.html` link to
`releases/latest`, **not** a version-pinned URL — so routine releases need **no**
download-link edits. Only touch public copy when a headline feature warrants it:

- `docs/index.html` `<meta name="description">` / `og:description` /
  `twitter:description` — refresh wording if a marquee feature changed.
- `README.md` Features list — add a bullet for a significant new capability.

Keep detailed notes in `docs/CHANGELOG.md`; keep README/website concise.

## Pre-Deploy Checklist (Everything Committed + Pushed Before Release)

- [ ] QA gate ran green (build + tests).
- [ ] `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` bumped in both configs.
- [ ] `docs/CHANGELOG.md` has an accurate `## [$VERSION]` section.
- [ ] Any warranted public-copy edits made.
- [ ] All of the above committed **and pushed to `origin/main`** (the script
      requires `HEAD == origin/main`).

## Credentials (Resolved by the Script)

- **Notarization** — `tools/release/notary-auth.sh` resolves credentials in order:
  App Store Connect API key → Apple-ID app-specific password → keychain profile
  `GHMenuStarsNotary`. If nothing is exported, put an API key (or Apple-ID creds)
  in `tools/release/.env` (auto-sourced). A notary **HTTP 403 "required agreement
  is missing"** is not a credential problem — the Account Holder must accept the
  pending Program License Agreement at developer.apple.com, then re-run.
- **Sparkle signing** — EdDSA private key in the login keychain (service
  `https://sparkle-project.org`, account `ed25519`), or point `SPARKLE_ED_KEY_FILE`
  at a key file. The script exits early if neither is present.
- **Developer ID** — signing identity via `DEV_ID_APP` (or resolved by
  `notary-auth.sh`).

## Run the Release

Interactive (recommended — pauses at a `[y/N]` gate showing version/tag/identity,
and you can read the generated Sparkle notes before it publishes):

```bash
VERSION=X.Y.Z tools/release/deploy-stargazer-bar.sh
```

Non-interactive (only after the release notes were reviewed):

```bash
VERSION=X.Y.Z SKIP_CONFIRM=1 tools/release/deploy-stargazer-bar.sh
```

The script then, in order: builds Release, signs with hardened runtime,
notarizes + staples the app, builds and notarizes the DMG + Sparkle zip,
checksums, generates release notes from the CHANGELOG, generates the signed
appcast, creates the GitHub release and uploads assets, commits + pushes
`docs/appcast.xml`, waits for the appcast to go live, and updates the Homebrew
cask (`UPDATE_CASK=1` by default). A Release build can spend several minutes in
`swift-frontend` whole-module optimization — that is normal progress, not a hang.

Useful env overrides: `SKIP_CONFIRM=1`, `UPDATE_CASK=0` (skip Homebrew),
`ALLOW_EXISTING_RELEASE=1` (replace assets/notes/appcast for an existing tag on
re-run).

## Verify + Failure Handling

- After it finishes: `tools/release/verify-deployment.sh` (or re-run if a check
  hit a transient GitHub/network 5xx before concluding rollback).
- The tag is `v$VERSION`. To re-run after a partial failure, fix the cause and
  re-run with `ALLOW_EXISTING_RELEASE=1` (release/appcast steps are idempotent).
- There is no rollback script in this repo — to undo, delete the GitHub release +
  tag (`gh release delete v$VERSION`, `git push origin :v$VERSION`) and revert the
  appcast commit, only after reviewing what actually published.
