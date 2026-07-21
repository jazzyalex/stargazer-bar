# Keychain silent path made structurally silent — plan

Date: 2026-07-20
Status: implemented (2026-07-20). Silent reads rebuilt on a read-only type,
migration writes moved to user-action paths only, legacy deletes gated on a
confirmed combined write, launch diagnostics added.

Backlog source: `docs/BACKLOG.md` — "Keychain password prompt on launch after
an update". Predecessor spec:
`docs/superpowers/specs/2026-07-16-repository-settings-redesign.md` (Part A).

## Problems

1. **`loadSilently()` can violate its own contract.**
   `GitHubCredentialStore.loadSilently()` is documented "never shows keychain
   UI", but when the combined item is missing/denied and a legacy item is
   readable, `migrateFromLegacy(interactive: false)` performs keychain
   **writes** (`save()` plus two `deleteToken()`s) *outside* the
   `SecKeychainSetUserInteractionAllowed(false)` bracket. `saveToken` starts
   with `SecItemUpdate`, which blocks on the ACL password dialog when the
   combined item exists but its ACL no longer trusts the running binary. So the
   silent path is silent for reads but not for the migration writes it
   triggers.

2. **Migration can destroy credentials.** `migrateFromLegacy` does
   `try? save(creds)` — swallowing failure — and then unconditionally deletes
   both legacy items. A failed combined write followed by the deletes loses the
   stored tokens permanently. Separately, when one legacy item is readable and
   the other is access-denied, the denied item is deleted even though its token
   was never carried into the combined item.

3. **Silence is enforced by convention, not by construction.** The
   silent/interactive distinction is a `Bool` threaded through
   `readCombined(interactive:)` / `migrateFromLegacy(interactive:)`. Nothing
   stops a future change from adding another write to the "silent" branch.

4. **No evidence trail.** The reported symptom (password prompt on launch
   after installing the 0.7.0 update) could not be reproduced from this
   checkout, and the app logs nothing about what the launch-time silent reads
   saw. The next occurrence would produce another vague user report instead of
   data.

### What is ruled out (verified 2026-07-20, do not re-investigate)

- The launch *read* path is already silent: `AppDelegate` wires all providers
  to `GitHubCredentialStore.loadOAuthTokenSilently()` / `loadPATSilently()`,
  which reach `KeychainTokenStore.silentLoadOutcome()` and its interaction
  bracket. The only interactive call site is `SettingsView.swift`
  (`refreshDirectory(interactive: true)`), gated on explicit user actions.
- `UpdaterController` / Sparkle never touch the login keychain.
- No `SecItem*`/`SecKeychain*` calls exist outside
  `GHMenuStars/Persistence/KeychainTokenStore.swift`.

### A plausible (unproven) trace for the reported prompt

The unbracketed migration write needs *legacy items readable* AND a
*stale-ACL combined item present* at once. That combination exists on a
developer machine that mixes build channels (the spike itself confirmed
cross-cert items deny silently):

- combined item created by an Apple-Development-signed Debug build,
- legacy items created by an older Developer-ID release,
- then a downloaded Developer-ID release update launches:
  combined → denied silently → legacy → readable silently (same Developer ID
  cert) → `migrateFromLegacy` calls `save()` → `SecItemUpdate` on the denied
  combined item → **password dialog at launch**.

This fits the report ("observed on the 0.7.0 update", reporter is the
developer) but is not proven; the fix below removes the mechanism regardless,
and the new diagnostics will show which state the next real update lands in.

## Goals

- The silent path is **incapable of keychain UI by construction**: it is built
  exclusively on a read-only type that owns no write/delete seams.
- Zero keychain writes or deletes on launch, background refresh, badge update,
  or update install. Migration writes happen only on user-action paths.
- **Never lose credentials**: a legacy item is deleted only immediately after
  a combined write that (a) succeeded and (b) contains a value for that item's
  slot.
- Launch-time diagnostic logging of the silent outcome per store
  (found / absent / accessDenied), token-free, so the next real update
  produces evidence.

## Non-goals

- Not claiming to fix the reported symptom — it was never reproduced locally
  and must be verified on a real downloaded signed update (see Verification).
- No change to OAuth scopes, device flow, PAT flows, or the Settings UI.
- No move to the data-protection keychain.
- Public-only "never touch the credential store at all at launch" gate:
  investigated and deferred (see below).

## Design

### Part A — `KeychainTokenStore.SilentReader` (type-level silence)

New nested type holding **only** what a silent read needs:

```swift
struct SilentReader {
    let service: String
    let account: String
    var setUserInteractionAllowed: (Bool) -> OSStatus  // seam, defaults to SecKeychainSetUserInteractionAllowed
    var copyMatching: CopyMatching                      // seam, defaults to SecItemCopyMatching
    func outcome() throws -> SilentLoadOutcome
}
```

- The existing `silentLoadOutcome()` implementation (LAContext +
  `kSecUseAuthenticationUISkip` query, dialog-in-flight last-known-cache
  check, interaction bracket) moves into `SilentReader.outcome()`.
  `KeychainTokenStore.silentLoadOutcome()` becomes a delegation through
  `var silentReader: SilentReader`, so all existing callers and tests keep
  their behavior.
- The type has no update/add/delete closures, so no code path built on it can
  write, delete, or prompt. That is the structural guarantee — not another
  flag.
- **Bracket hardening:** the return value of
  `SecKeychainSetUserInteractionAllowed(false)` was previously ignored. If
  disabling interaction fails, the read is *not* guaranteed silent, so
  `outcome()` now refuses to call `copyMatching` at all and degrades to the
  last-known cache / `.accessDenied`. (Injectable seam so the branch is
  testable.)
- Shared statics (`interactionLock`, `stateLock`, `interactiveReadsInFlight`,
  `lastKnownTokens`) stay on `KeychainTokenStore`; the nested type accesses
  them. Key/remember/forget helpers become static, keyed by (service,
  account), with the existing instance methods delegating.

### Part B — `GitHubCredentialStore.loadSilently()` is read-only

`loadSilently()` delegates to a `private static` function whose parameters are
three `SilentReader`s and nothing else — the write seams are not in scope:

- Read the combined item silently; if it decodes, return it.
- Otherwise read the two legacy items silently and return their tokens
  (or nil if both empty). **No migration write, no deletes.**

Consequence: for a legacy-item user, every silent load re-reads the legacy
items until a user action creates the combined item. That is two extra silent
`SecItemCopyMatching` calls per poll — cheap, and correct by the prompt
policy ("defer the heal to the next explicit action", per the backlog).

`readCombined(interactive:)` / `migrateFromLegacy(interactive:)` and their
`Bool` disappear; the interactive path keeps its own explicit methods.

### Part C — migration writes: user-action paths only, loss-proof ordering

**Delete-ordering change (safety-critical, called out per requirements):**

- Legacy cleanup moves *into* `save(_:)`, immediately after
  `combined.saveToken` returns without throwing — i.e. after `SecItemAdd`/
  `SecItemUpdate` reported `errSecSuccess`, which is the durability
  confirmation. If the combined write throws, **no legacy item is touched**
  (previously: `try? save` swallowed the failure and both legacy items were
  deleted anyway — a credential-loss bug).
- Per-slot guard: `legacyOAuth` is deleted only when the just-written
  credentials contain an `oauth` value; `legacyPAT` only when they contain a
  `pat`. This closes a second pre-existing loss path: one legacy item readable
  + the other access-denied previously deleted the denied item without ever
  migrating its token.
- Because cleanup lives in `save(_:)`, *every* successful user-action write
  (`setOAuth` on device-flow completion, `setPAT`, interactive migration)
  retires the legacy items it superseded — faster convergence to the
  combined-only state, and no silent-path caller can reach it
  (`save`/`setOAuth`/`setPAT` are only called from user actions and are not
  reachable from `loadSilently()` by construction).
- `loadRequestingAccessIfNeeded()` (interactive): combined found → return;
  otherwise read legacy via `loadTokenRequestingAccessIfNeeded()` (may prompt
  once, as designed) and `try? save(creds)` — persistence and legacy retirement
  in one place, skipped entirely on failure.

### Part D — launch diagnostics

- `SilentLoadOutcome.diagnosticLabel`: `"found"` / `"absent"` /
  `"accessDenied"` — a constant per case; the token associated value is never
  interpolated.
- `GitHubCredentialStore.silentDiagnostics()` returns the three labels
  (combined / legacyOAuth / legacyPAT), built on `SilentReader`s only; a read
  error maps to `"error"`.
- `logLaunchSilentDiagnostics()` writes one `os.Logger` line
  (subsystem = bundle id, category `Keychain`, level `.notice` so it persists
  in the unified log):
  `Launch silent credential check: combined=… legacyOAuth=… legacyPAT=…`.
- `AppDelegate.applicationDidFinishLaunching` fires it once on a utility
  queue. After the next real update, `log show --predicate 'category ==
  "Keychain"'` answers which state the machine was actually in.

### Investigated and deferred — public-only users not touching the store at all

`GitHubRepoAccess` already gates PAT reads on
`settings.hasPrivateRepoToken` (non-keychain). An equivalent OAuth gate was
investigated and **deferred** as not clean:

- No reliable existing signal: `RepoDirectory.login` is only written after a
  successful Settings directory refresh, so it is not "has OAuth token".
- A new `AppSettings.hasGitHubOAuthToken` mirror would need seeding for
  existing users — which itself requires a keychain read on first launch — and
  a stale `false` silently downgrades an authenticated user to anonymous
  polling (60 req/h rate limit), a worse failure mode than a silent read.
- `GitHubClient`'s `tokenProvider` closures run off the main actor;
  `SettingsStore` is `@MainActor`, so the gate would need cross-actor access
  or a per-poll `UserDefaults` JSON re-decode.
- After Parts A–B, launch-time reads are structurally incapable of prompting,
  so the gate would buy no prompt-behavior improvement — the public-only
  "never prompted under any circumstance" bar is met without it.

## Testing

Seam-injected via the existing `InMemoryKeychain` harness in
`GHMenuStarsTests/ServiceLogicTests.swift`, extended with a mutation log
(records every update/add/delete per service), per-service read denial, and
per-service write failure. Written failing-first:

- Silent load with combined access-denied + readable legacy items: returns the
  legacy credentials, **zero** write/delete calls on any store (previously:
  wrote combined + deleted both legacy items).
- Silent load with combined absent + readable legacy items: returns them,
  zero mutations, legacy items still present.
- Silent load with nothing stored: nil, zero mutations (regression guard).
- Interactive migration with a failing combined write: returns the tokens,
  legacy items **not** deleted, retried and completed on a later interactive
  load once writes succeed.
- Interactive migration happy path: combined round-trips both tokens, legacy
  items deleted, subsequent silent loads read combined only (rewrite of
  `testCredentialStoreMigratesLegacyItemsThenDeletesThem`, which previously
  asserted that *silent* load migrates — the defective behavior).
- Per-slot delete guard: legacy PAT readable + legacy OAuth denied →
  migration writes `{pat}` and deletes only the legacy PAT item; the denied
  OAuth item survives.
- `SilentReader`: refuses to read when interaction cannot be disabled
  (`copyMatching` not called; last-known / `.accessDenied` returned).
- Diagnostics: label mapping per outcome; the log line never contains token
  material.
- All existing keychain/credential-store tests keep passing (one rewritten as
  noted above; the query-shape and healing tests are untouched).

## Verification still required (cannot be done from this checkout)

The original symptom was never reproduced locally. Proof requires a real
signed, downloaded vN → vN+1 update on a machine with pre-existing items,
observing (a) no prompt and (b) the new diagnostic line. Until then this fix
removes the only in-app mechanism found that *could* prompt on the silent
path; it does not claim to have fixed the observed report.

## Risks / open questions

- Deferred migration means legacy-item users do two extra silent reads per
  poll until their first user-action write. Accepted: reads are cheap and
  structurally silent.
- If the combined item is deleted (`save` of empty credentials) while
  un-retired legacy items still exist, the legacy tokens become readable
  again. Narrow (requires disconnecting before any successful combined write)
  and superseded-token-only; accepted.
- `SecKeychainSetUserInteractionAllowed` is deprecated API but remains the
  only switch that actually silences the login-keychain ACL dialog (verified
  on macOS 15, see `KeychainTokenStore` doc comment); unchanged here.

## Backward compatibility

- Legacy items now survive until the first successful user-action write
  instead of the first silent load — strictly safer; no user-visible change.
- The combined item format, service/account names, and all public call sites
  (`AppDelegate`, `SettingsView`, `GitHubRepoAccess`) are unchanged apart from
  the added diagnostics call.
