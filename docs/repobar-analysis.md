# RepoBar Analysis

RepoBar is the closest active neighbor to Stargazer Bar, but it is not the same product. RepoBar is a GitHub work dashboard in the menu bar. Stargazer Bar should stay a tiny public momentum counter.

Sources checked:

- RepoBar website: https://repobar.app/
- RepoBar repository README: https://github.com/steipete/RepoBar
- RepoBar product spec: https://github.com/steipete/RepoBar/blob/main/docs/spec.md
- RepoBar cache design: https://github.com/steipete/RepoBar/blob/main/docs/cache.md

## Positioning

RepoBar's promise is "GitHub work visible without living in tabs." It covers CI, issues, PRs, releases, local checkout state, contribution heatmaps, cache/archive fallback, rate limits, and a CLI. It is aimed at people managing many active repositories.

Stargazer Bar's promise should be smaller and more emotional:

> A tiny menu-bar counter for public GitHub momentum.

That means:

- No mandatory GitHub login.
- No broad private-repo access.
- No PR, issue, CI, local checkout, worktree, or repo-sync scope.
- Any public repository should be trackable, whether or not the user owns it.
- Stars and release downloads stay first-class, not buried inside a dashboard.
- The app should feel fun and glanceable, not operational.

## Where RepoBar Is Too Big For Us

Do not copy these directions for 0.2:

- Auth-first repository browser.
- GitHub App installation flow.
- Private organization repositories.
- Local project scanning.
- Issues, pull requests, CI, checks, branches, worktrees, dirty files, or auto-sync.
- SQLite cache/archive machinery.
- CLI parity.
- Rate-limit meter as a primary menu-bar display.
- Contribution graph/header as a central UI object.

These are valuable for RepoBar, but they would make Stargazer Bar feel like a harvester. Our advantage is that the app can be understood before the first click.

## Small Ideas Worth Copying

### 1. Pinned / Visible / Hidden Vocabulary

RepoBar's repository browser uses `Visible`, `Pinned`, and `Hidden` states. Stargazer Bar can borrow a lighter version:

- `Pinned`: eligible for menu-bar display.
- `Visible`: listed in the dropdown, but not the active menu-bar counter.
- `Hidden` is probably too much for 0.2; `Remove` is clearer for a tiny app.

For 0.2, use `Pinned` only if multiple repos can rotate or aggregate. Otherwise call it `Shown in menu bar`.

### 2. Repository Rows With Tiny Metrics

RepoBar's repo cards show several metrics at once. Stargazer Bar can compress this into simple menu rows:

```text
Stars  stargazer-bar          128   +4
Stars  openclaw/openclaw   369.2k   +920
Dl     Latest downloads      1.2k   +31
```

The useful idea is density, not cards. A menu should show all tracked repos without opening a heavy window.

### 3. Per-Repo Submenus

RepoBar uses rich submenus for each repository. Stargazer Bar can use minimal submenus:

- Open on GitHub
- Copy repo name
- Show in menu bar
- Check now
- Remove

Avoid nested analytics. The submenu is for actions, not a second dashboard.

### 4. Cache-First Feeling

RepoBar opens from cached data first and refreshes in the background. Stargazer Bar already persists the latest values in `UserDefaults`. For 0.2, preserve that behavior across multiple repos:

- The menu bar should never go blank during refresh.
- Each repo row should keep its last known stars/downloads.
- Stale or rate-limited rows should show a small status line rather than replacing data with an error.

No SQLite is needed for 0.2. Per-repo ETags and timestamps in the existing `TrackedRepo` model are enough.

### 5. Manual Rules Survive Network Trouble

RepoBar keeps manual repository rules even when auth or access changes. Stargazer Bar should do the same for public repos:

- If a repo fails temporarily, keep it in the list.
- Show `Last checked ...` and the error in the menu/settings.
- Let the user remove it explicitly.

### 6. Rate-Limit Transparency, Not Rate-Limit Product

RepoBar has a full rate-limit submenu. Stargazer Bar only needs a tiny warning:

- Show a single menu row when rate-limited.
- Include reset time.
- Skip background refreshes until reset.

Do not make rate limit health a permanent display mode.

### 7. Quick Actions Stay Close To The Counter

RepoBar makes click-throughs easy. Stargazer Bar should keep that:

- Click repo row opens GitHub.
- Secondary/submenu action can copy `owner/repo`.
- Release/download line can open the latest release page once the model stores it.

## 0.2 Product Lessons

The gap is not "RepoBar but smaller." The gap is "menu-bar Tamagotchi for GitHub repo momentum."

For 0.2, the two strong directions are:

1. Multi-repo tracking without turning into a dashboard.
2. Funny sounds and tiny celebrations when numbers move.

Multi-repo should answer one question first: what goes in the menu bar when there is more than one repo?

The safest 0.2 answer is:

- Keep one primary menu-bar counter.
- Let the user choose its display mode:
  - selected repo stars
  - selected repo downloads
  - total stars across tracked repos
  - total downloads across tracked repos
  - rotating repo every N seconds/minutes
- Put all repo details in the dropdown.

That keeps the app tiny while making multi-repo useful.
