# Shiplog — Requirements

Status: **implemented** (v0.1.0, live-verified on Omarchy 4 / Quattro)
Target: Omarchy 4 / Quattro shell (Quickshell plugin API)
Plugin ID: `io.github.joshuaswarren.shiplog`
Kind: `bar-widget` (the panel is the widget's own popout; the shell's separate
`panel` kind is for standalone surfaces like the OSD, so the installed
first-party convention — weather, clock — is a single bar-widget entry point)

## 1. Problem

Every developer widget in the marketplace shows work *pending* — inboxes, review queues, CI pipelines, dirty branches. Nothing shows work *done*. Shiplog is proof-of-done in the bar: a running count of what actually shipped today (merged PRs, pushed commits, closed issues), with the day's log one click away. It answers "did I actually finish anything?" with evidence instead of vibes.

## 2. Goals

- G1: Bar chip with today's shipped count, split by type on hover (e.g. `3 ⇡  1 ⇗  2 ✓` = commits pushed / PRs merged / issues closed).
- G2: Click opens a panel listing the day's items newest-first, grouped by repository, each deep-linking to the browser.
- G3: Data via the `gh` CLI (GitHub API) — merged PRs authored by the user, issues closed by the user, and commits pushed to any branch, since local midnight.
- G4: Optional local-repos source: scan configured directories for commits authored today by the local git identity (works offline, covers non-GitHub remotes).
- G5: A "week strip" at the bottom of the panel: seven small day-counts, today highlighted. Receipts, not analytics.
- G6: Graceful zero state: "Nothing shipped yet — the day is young." Never guilt-toned.
- G7: Theme-aware; polls respect API rate limits (conditional requests, ≥5 min interval).

## 3. Non-goals

- NOT a contribution graph, streak tracker, or gamification layer. No badges, no goals, no comparisons. The number resets at midnight and that is the point.
- NOT a GitHub inbox or review queue (several plugins already do this well).
- NOT a time tracker.
- No GitLab/Gitea in v1 (the local-repos source covers their commits; API adapters are a documented extension point, not a launch requirement).

## 4. UX specification

### 4.1 Bar chip

| State | Appearance |
|---|---|
| Zero shipped | Dim ship glyph, no number (or hidden, per `hideWhenZero`) |
| n shipped | Ship glyph + total count in foreground token |
| New item detected | One brief accent pulse (no sound) |
| Auth/network error | Glyph with small warning dot; tooltip explains; never blocks the bar |

Left-click: toggle panel. Right-click: refresh now.

### 4.2 Panel

- Header: date + total ("Shipped today — 6").
- Body: items grouped by repo, newest first. Each row: type icon, title (PR/issue title or commit subject), time. Click opens the URL via the default browser; local-only commits show repo path instead of a link.
- Footer: week strip (G5) + last-refresh timestamp.
- Keyboard: arrows navigate, Enter opens, Esc closes.
- `open(payloadJson)` / `close()` per the Quattro contract.

## 5. Settings (inline on the `shell.json` plugin entry)

```json
{
  "id": "io.github.joshuaswarren.shiplog",
  "sources": ["github"],
  "localRepoDirs": ["~/src"],
  "pollMinutes": 5,
  "countCommits": true,
  "countMergedPrs": true,
  "countClosedIssues": true,
  "hideWhenZero": false,
  "dayBoundary": "00:00",
  "recapDir": ""
}
```

`dayBoundary` lets night owls end their "day" at e.g. 04:00. All times local.

## 6. Data & integration

- GitHub source shells out to `gh api` REST search with structured arguments (no string-interpolated shell). Requires `gh auth login` already done; plugin never handles tokens itself.
  - Merged PRs: `/search/issues?q=author:LOGIN+is:pr+is:merged+merged:>=DATE`.
  - Closed issues: `/search/issues?q=author:LOGIN+is:issue+is:closed+closed:>=DATE` (v1 = author).
  - Commits: `/search/commits?q=author:LOGIN+author-date:>=DATE`, deduplicated by SHA. Commit search indexes default branches; any-branch coverage comes from the local source. The events API was the original plan and is unusable: GitHub now returns `PushEvent` payloads with empty `commits[]` (verified 2026-08-21). REST search also draws on a separate rate meter from GraphQL, so `gh search` exhaustion elsewhere cannot blind the widget.
- Local source runs the bundled `scripts/local-commits.sh` (argument arrays, one `git log --all --since` per repo found one level under each `localRepoDirs` entry, authored by that repo's own `user.email`).
- Week strip is computed from a small local cache (`~/.local/state/omarchy/shiplog.json`, following the shell's state-dir convention) so it costs zero extra API calls.
- All parsing defensive: missing fields, empty results, and API errors degrade to the last good data plus the warning-dot state.

## 7. Security

- Read-only integration: the plugin never creates, edits, or deletes anything on GitHub.
- Credentials stay inside `gh`'s own auth store; the plugin neither reads nor stores tokens.
- Subprocess calls use argument arrays; no user-configurable strings are ever passed through a shell.
- Local scan reads `git log` only from user-listed directories.

## 8. Acceptance criteria

- A1: With `gh` authenticated, merging a PR shows in chip + panel within one poll cycle.
- A2: A commit pushed to any branch increments the commit count exactly once (deduplicated across force-pushes).
- A3: With no network, local-repos commits still appear and the chip shows the warning dot for the GitHub source.
- A4: At `dayBoundary`, counts reset and yesterday's total appears in the week strip.
- A5: Zero state renders per G6; `hideWhenZero: true` removes the chip entirely.
- A6: Panel keyboard navigation works end-to-end; Enter opens the correct URL.
- A7: Poll traffic ≤ 1 request burst (three REST searches) per `pollMinutes`; every subprocess carries a hard `timeout` so a hung child degrades to the warning-dot state instead of freezing a source. (Conditional requests died with the events API; REST search responses are not usefully ETag-cacheable.)
- A8: Theme switch recolors chip and panel with no restart; horizontal and vertical bars both render.
- A9: `omarchy plugin validate .` passes.

## 9. Milestones

- M1: GitHub source + bar chip (A1, A2, A7).
- M2: Panel with grouped log + deep links (A5, A6).
- M3: Local-repos source, week strip, day boundary (A3, A4).
- M4: Polish — theming, vertical bar, README screenshots (A8, A9).

## 10. Resolved open questions

- Co-authored commits count: yes — commit search matches `author:`, and the
  local scan matches each repo's configured identity.
- "Copy day as Markdown": shipped in v0.1.0 (footer button, `c` key, and the
  `copy` IPC method).
- Save the shiplog somewhere: shipped as the recap archive. `recapDir` set
  means each shipped day is written to `<recapDir>/<YYYY-MM-DD>.md` at
  rollover, plus on demand via the `s` key and the `save` IPC method.
