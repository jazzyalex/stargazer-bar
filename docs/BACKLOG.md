# Backlog

Deferred, not-yet-scheduled work. Newest first. Move items into a dated plan
under `docs/superpowers/plans/` when picked up.

## Keychain password prompt on launch after an update — must never happen

Reported: 2026-07-16 (observed on the 0.7.0 update).
Priority: high (correctness / trust), but deferred for now.

**Symptom.** After installing an app update, Stargazer Bar prompts for the
Keychain (login) password *on startup*. This should never happen — launch and
any passive/background work must be completely silent.

**Also.** Users who only link **public** repos manually never need GitHub
credentials at all, yet can still be prompted. A public-only user should never
see a Keychain prompt under any circumstance.

**Expected behavior (the bar).**
- Zero Keychain prompts on launch, background refresh, badge updates, or update
  install — degrade to last-known/cache instead.
- Prompts only on deliberate user actions (Refresh, Reconnect, adding a private
  repo).
- Public-only usage: never prompt, ever.

**Context / likely causes to investigate.** This is a regression against the
explicit goal of the 0.7.0 credentials redesign
(`docs/superpowers/specs/2026-07-16-repository-settings-redesign.md`, Part A:
"zero prompts on launch"). The silent path is supposed to be wrapped in a
`SecKeychainSetUserInteractionAllowed(false)` bracket and fail silently. Things
to check:
- A launch-time read path (`GitHubCredentialStore.loadSilently()` callers in
  `AppDelegate` / `GitHubRepoAccess`) that isn't actually going through the
  silent bracket, or a caller still hitting an interactive path.
- The legacy→combined **migration** on first post-update launch: reading the two
  legacy Keychain items during `loadSilently()` may prompt if their ACL is stale
  after the re-signed update, instead of failing silently and deferring the heal
  to the next explicit action.
- The spike's "same identifier + same signing certificate reads silently across
  a code-hash change" assumption may not hold for a real Developer ID vN→vN+1
  **release update** the way it did in the manual spike — verify on a real
  downloaded update, not a local rebuild.
- Ensure public-only launches never touch the credential store at all when no
  private repos are tracked and no OAuth token is expected.

**Done when.** A user upgrading from a prior version, and a public-only user,
both launch the updated app with no Keychain prompt; prompts appear only on
explicit Refresh/Reconnect/add-private actions.
