# Shiplog — Architecture

Follows the first-party rich-widget pattern (`omarchy.weather`, `omarchy.clock`):
one `bar-widget` plugin whose entry point loads an internal popout panel.
The `panel` plugin kind is for standalone floating windows (OSD); anchored
popouts are part of the bar-widget contract, so Shiplog declares
`kinds: ["bar-widget"]` only.

## Modules

| File | Role |
|---|---|
| `BarWidget.qml` | Thin chip wrapper. Loads `Panel.qml`, injects `bar`/`settings`/`anchorItem`/`hostWidget`, forwards the shell shape contract (`open`, `close`, `opened`, `popoutSwitchClosing`, `closeForPopoutSwitch`). |
| `Panel.qml` | `qs.Ui Panel` subclass. Owns the data engine (Process + Timer polling), all mutable state, and the popout UI (`KeyboardPanel` + `PanelKeyCatcher`). |
| `Model.js` | Pure functions. No QML/Quickshell imports. All parsing, day-boundary math, dedup, grouping, week-strip and cache logic. Unit-tested. |
| `scripts/local-commits.sh` | Enumerates repos one level under each configured dir; emits TSV of today's commits. Arguments only; no shell interpolation of config values. |

## Data shapes

```
ShipItem  { type: "commit"|"pr"|"issue", repo: string, title: string,
            url: string|null, ts: number (ms epoch), sha: string|null }
Counts    { commits: number, prs: number, issues: number, total: number }
StateFile { version: 1, days: { "YYYY-MM-DD": Counts } }   // week strip cache
```

- `repo` is `owner/name` for GitHub items, absolute path for local-only commits.
- `url` is null for local-only commits (row shows repo path, no link).
- StateFile lives at `~/.local/state/omarchy/shiplog.json`. Only `Panel.qml`
  writes it. Pruned to 14 days.

## Model.js API (frozen contract)

```
dayStartMs(nowMs, boundary)            -> ms epoch of current logical day start ("HH:MM" boundary)
dayKey(tsMs, boundary)                 -> "YYYY-MM-DD" logical day for a timestamp
normalizeSearchPrs(jsonText)           -> ShipItem[]      // REST /search/issues is:pr response body
normalizeSearchIssues(jsonText)        -> ShipItem[]      // REST /search/issues is:issue response body
normalizeSearchCommits(jsonText)       -> ShipItem[]      // REST /search/commits response body
normalizeLocalCommits(tsvText)         -> ShipItem[]      // local-commits.sh output
mergeItems(listOfLists, dayStartMs2)   -> ShipItem[]      // dedup (sha for commits, url for pr/issue), filter >= dayStart, newest-first
groupByRepo(items)                     -> [{ repo, items }]  // group order by newest item
counts(items)                          -> Counts
updateStateCache(stateText, key, cnts) -> StateFile object  // tolerant of missing/corrupt input
weekStrip(stateObj, todayKey, boundary)-> [{ key, label, count, isToday }] x 7, oldest first
markdownRecap(items, dateLabel)        -> string          // "copy day as Markdown"
recapFilePath(dir, key)                -> string          // "<dir>/<key>.md" for a validated absolute dir + day key, else ""
```

All functions defensive: null/empty/garbage input returns empty results, never throws.

## Panel public surface (read by BarWidget)

`label` (chip text), `totalCount`, `todayCounts` (Counts), `hasError` (bool,
any source failing while last-good data shows), plus the `qs.Ui Panel`
lifecycle: `opened`, `open()`, `openFromHotkey()`, `close()`, `toggle()`,
`refresh()`, `popoutSwitchClosing`, `closeForPopoutSwitch()`.

## Settings (inline on the shell.json layout entry)

`sources` (["github"], may include "local"), `localRepoDirs` (["~/src"]),
`pollMinutes` (5, min 5), `countCommits` (true), `countMergedPrs` (true),
`countClosedIssues` (true), `hideWhenZero` (false), `dayBoundary` ("00:00"),
`recapDir` ("" = archive disabled).
Read via `setting(name, fallback)`.

## Polling

One burst per `pollMinutes` tick, all REST (separate meter from GraphQL, which
the rest of the fleet exhausts; the events API is unusable because GitHub now
returns PushEvents with empty `commits[]`, verified 2026-08-21):

- merged PRs:    `gh api /search/issues?q=author:LOGIN+is:pr+is:merged+merged:>=DATE&per_page=100`
- closed issues: `gh api /search/issues?q=author:LOGIN+is:issue+is:closed+closed:>=DATE&per_page=100`
- commits:       `gh api /search/commits?q=author:LOGIN+author-date:>=DATE&per_page=100`
- local scan:    `scripts/local-commits.sh <sinceEpoch> <dirs...>`

LOGIN comes from `gh api user` once per session (search queries cannot use
@me). DATE is the UTC date of (logical day start - 24h); Model.mergeItems does
the exact local-day filter. Commit search indexes default branches only;
any-branch and non-GitHub coverage comes from the local source.
Failures keep last-good data and set the warning-dot state.

### Response field mapping

- PR/issue: url = html_url; ts = pull_request.merged_at, else closed_at, else
  updated_at; repo parsed from repository_url tail (".../repos/OWNER/NAME").
- commit: sha; url = html_url; repo = repository.full_name; title = first line
  of commit.message; ts = commit.author.date (ISO with offset).
