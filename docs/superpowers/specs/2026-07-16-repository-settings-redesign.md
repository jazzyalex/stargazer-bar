# Repository settings redesign — design

Date: 2026-07-16
Status: implemented (2026-07-16). ACL spike confirmed; single combined store,
repo directory cache, silent/interactive refresh, three-zone layout, and
team-signed Debug all landed with tests.

## Problems

1. The Repository settings tab is cramped and the "all your GitHub repos" picker
   is buried at the bottom, appears only after clicking Load Repos, and renders
   below the fold.
2. Reopening Settings shows an empty list — the loaded repos live in view-only
   `@State` (`publicRepos`) discarded on quit. Private repos, which come only
   from a second (PAT) read, are easy to miss.
3. Load Repos prompts for the keychain password **twice**. Root cause: it reads
   two separate keychain items (OAuth token + private-repo PAT). The app is
   **unsandboxed** (`CODE_SIGN_ENTITLEMENTS = ""`), so both items live in the
   login keychain with ACLs bound to the exact signed binary; every re-sign
   (each release update, each local rebuild) invalidates both ACLs → one prompt
   per item.

## Goals

- Repo list (public + private) is persistent and visible immediately on opening
  Settings, refreshed silently in the background.
- At most **one** keychain prompt, and **zero** prompts on launch or on passive
  actions. Prompts happen only on explicit user actions (Refresh, Reconnect,
  adding a private repo).
- Notarized release **updates** read stored tokens silently (no re-prompt).
- Local ad-hoc Debug rebuilds also stay silent, by giving Debug a stable team
  identity.
- A cleaner Repository layout organized around the always-present repo list.

## Non-goals

- Not migrating to the data-protection keychain (would require
  `keychain-access-groups` entitlement + provisioning; out of scope for an
  unsandboxed Developer ID app).
- No change to OAuth scopes or the device-flow / PAT acquisition flows.
- The Menu Bar display section (Counter / Shown repo / Trend range / Radar
  activity) is unchanged.

## Design

### Part A — Credentials: one keychain item, same-developer trust

"Team" throughout this doc means the **Apple code-signing Team ID**
(`24NDRU35WD`, "Alex M") — the identity Apple issues to an individual developer
and stamps on every signed release. It is not a GitHub team/org, and a solo
developer already has exactly one; nothing to set up.

Replace the two-item scheme (`StargazerBar.GitHubOAuth`, `StargazerBar.GitHubPAT`)
with a single item holding both tokens.

- New `GitHubCredentialStore` (in `GHMenuStars/Persistence/`), wrapping today's
  `KeychainTokenStore` seams (`copyMatching`, `updateItem`, `addItem`,
  `deleteItem`) so it stays unit-testable.
- Model: `struct GitHubCredentials: Codable, Equatable { var oauth: String?; var pat: String? }`,
  stored as JSON in one item: service `StargazerBar.GitHubCredentials`, account `github`.
- **Read semantics** mirror the current `KeychainTokenStore`:
  - `loadSilently() -> GitHubCredentials?` — never shows UI (reuses the
    `SecKeychainSetUserInteractionAllowed(false)` bracket + last-known cache
    already built for the silent path). Used by launch polling and Settings
    auto-refresh.
  - `loadRequestingAccessIfNeeded() -> GitHubCredentials?` — user-initiated;
    may show the password dialog once, then heals (delete + recreate) so the
    running binary owns the item. Used by Refresh / device-flow / add-private.
  - `save(_:)`, `update { }`, and `clearOAuth()` / `clearPAT()` helpers.
- **Same-developer access policy (Apple signing identity).** Spike result
  (2026-07-16, verified with two re-signed binaries, identifier
  `com.jazzyalex.StargazerBar`, both certs OU `24NDRU35WD`): an item created by
  a properly team-signed build is read **silently** by any later build of the
  same identifier + same signing certificate, even with a different code hash.
  **No custom `SecAccess` / partition-list code is needed** — plain `SecItemAdd`
  from a signed build suffices. Requirements: (a) the item is created by a
  team-signed build (the heal's delete+recreate ensures this), and (b) Debug is
  team-signed, not ad-hoc.
  - Confirmed silent: Developer ID vN → vN+1 (release update), and Apple
    Development rebuild → rebuild (dev loop).
  - Confirmed one-time prompt: cross-cert (the release Developer ID item read by
    a local Apple Development build, or vice versa). The heal re-owns the item
    under the running identity, silent thereafter until build channels are
    switched again. Dev-only edge; users never hit it.
- **Migration** (from the two legacy items), opportunistic and prompt-free where
  possible:
  - `loadSilently()`: if the combined item is absent, silently read the legacy
    OAuth and PAT items; if either is found, return them **and** best-effort
    write-through to the combined item, then delete the legacy items.
  - `loadRequestingAccessIfNeeded()`: same, but the legacy reads may prompt
    (once) if their ACL is already stale. After a successful combined write, the
    legacy items are deleted, so this happens at most once.
- **Prompt policy** (honors the original requirement — prompt only on real
  actions):
  - Silent-by-default everywhere: launch polling, Settings auto-refresh, badge —
    never prompt; degrade to last-known / cache.
  - Explicit-only: Refresh button, Reconnect, adding a private repo — may prompt
    once and heal.

### Part B — Repo directory cache + auto-refresh

- New `RepoDirectoryStore` (in `GHMenuStars/Persistence/`), following the
  `TrackedRepoStore` convention: JSON in `UserDefaults`.
  - Persists: `[GitHubRepoSummary]` (extend `GitHubRepoSummary` from `Decodable`
    to `Codable`), the authenticated `login: String?` (for "Connected as @user"),
    and `lastRefreshed: Date?`.
  - API: `load() -> RepoDirectory?`, `save(_:)`, with corrupt-data tolerance
    like `TrackedRepoStore.decodeRepos`.
- Refresh logic (extracted from today's `SettingsView.loadPublicRepos`):
  - `refreshSilently()` — read credentials via `loadSilently()`. If `oauth`
    present, fetch accessible public repos; if `pat` present, fetch accessible
    private repos; merge (reuse existing `merged(public:private:)`); update the
    cache and the published list. On silent-read failure or missing token,
    **no-op** (keep the cache, no prompt).
  - `refreshInteractively()` — the Refresh action. Read via
    `loadRequestingAccessIfNeeded()` (may prompt once + heal), same fetch/merge,
    update cache. If there is no OAuth token at all, start the device flow.
- Settings `onAppear`: render the cached list immediately, then call
  `refreshSilently()` in the background.

### Part C — Repository tab layout

Three zones (replacing today's Repositories / Menu Bar / GitHub stack, Menu Bar
kept as-is between them or after — final placement during implementation):

1. **Your repositories** — the tracked repos shown in the menu bar. Unchanged
   behavior (select for menu bar, per-repo sound, mute, remove; 5-repo cap).
2. **Add a repository** — a search field filtering the cached directory, an
   `All / Public / Private` filter, and each row has a `+` that adds it directly
   (respecting the 5-repo cap and reusing the existing add/validate path).
   Private repos show a lock and a "private" tag inline. A secondary
   "or paste owner/repo or URL" field + Add stays for repos not in the list.
   This merges today's manual field and the buried picker into one flow. The
   `Load Repos` button is removed as the primary path.
3. **Connection** (de-emphasized footer) — "Connected as @user · Refresh" and
   "Private token · Manage", collapsing today's Reconnect / Load Repos / badge /
   PAT block. Refresh calls `refreshInteractively()`.

### Callers to update

- `AppDelegate` token providers and `GitHubRepoAccess` (`patProvider`,
  `ambientProvider`) switch from `KeychainTokenStore.loadGitHubOAuthToken()` /
  `loadGitHubPAT()` to `GitHubCredentialStore.loadSilently()` reading `.oauth` /
  `.pat`. They remain silent.
- `SettingsView` PAT management (`saveTokenAndResumeAdd`, `removePAT`,
  `validatePAT`) writes/reads through the combined store.
- Debug signing: set `DEVELOPMENT_TEAM = 24NDRU35WD`,
  `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY = "Apple Development"` for
  the Debug configuration so local rebuilds carry the stable team identity.

## Data flow

```
Launch:        pollers → GitHubCredentialStore.loadSilently() → tokens (no UI)
Open Settings: onAppear → RepoDirectoryStore.load() → show cache
                        → refreshSilently() → creds(silent) → fetch → merge → save + publish
Refresh click: refreshInteractively() → creds(may prompt once, heal) → fetch → merge → save
Add private:   validate → needs PAT → prompt inline → save to combined store → retry
```

## Error handling

- Silent credential read fails (stale ACL, pre-heal): no prompt; keep cache;
  pollers run unauthenticated (public) or skip private, exactly as today's
  silent path degrades.
- Interactive read cancelled: treated as "no token" → device flow / inline PAT
  ask, never a raw keychain error (existing behavior preserved).
- Refresh network failure: keep the cached list, surface a non-blocking message.
- Corrupt cache: discard and treat as empty (preserve corrupt blob for
  diagnostics like `TrackedRepoStore`).
- A dead PAT must never empty the picker: private fetch degrades to public-only
  (existing `loadPrivateReposIfAvailable` behavior).

## Testing

- `GitHubCredentialStore` (seam-injected, like existing `KeychainTokenStore`
  tests): combined round-trip; JSON encode/decode of `{oauth, pat}`; silent vs
  interactive status mapping; heal (delete+recreate) on access-denied; migration
  — first read returns legacy tokens, assert combined item written and legacy
  items deleted, subsequent reads use combined only.
- Team-trust access: **spike / manual CLI verification** (create from a
  team-signed build, re-sign a differently-hashed same-team binary, read →
  assert no prompt). Documented, not a unit test.
- `RepoDirectoryStore`: encode/decode round-trip; corrupt-data tolerance;
  `GitHubRepoSummary` Codable round-trip.
- Refresh logic: silent refresh with no creds keeps cache and never prompts;
  interactive path takes the heal branch once; merge/dedup via existing
  `merged` tests.
- UI: no unit coverage (SwiftUI layout); manual QA — open Settings shows cached
  list incl. private; add via `+`; Refresh prompts at most once then silent.

## Risks / open questions

- **ACL suppression across re-signed binaries — RESOLVED by spike (2026-07-16).**
  Same identifier + same signing certificate reads silently across a code-hash
  change, with no custom keychain-access code. So no partition-list/`SecAccess`
  work is required; the implementation just relies on plain `SecItemAdd` from a
  team-signed build plus the existing heal. The only residual prompt is the
  dev-only cross-cert switch, healed once.
- Debug team signing requires the developer's Apple Development cert + automatic
  signing configured for team `24NDRU35WD` (true for this developer). CI/release
  signing (Developer ID) is unchanged.
- Caching private repo **names** to `UserDefaults` on the local machine — same
  class of data already stored for tracked repos; acceptable.

## Backward compatibility

- First launch after upgrade migrates the two legacy keychain items into the
  combined item (silently if their ACL still trusts the binary, otherwise on the
  first interactive Refresh), then deletes them.
- Existing tracked repos and settings are untouched.
