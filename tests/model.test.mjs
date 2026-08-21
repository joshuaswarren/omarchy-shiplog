// Shiplog Model.js unit tests. Loads the QML-style script (plain function
// declarations, no module syntax) into a fresh vm context, exactly the way a
// non-QML host has to consume it, then exercises every frozen-contract
// function against real captured fixtures plus synthetic edge cases.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const source = readFileSync(join(root, "Model.js"), "utf8")

const ctx = vm.createContext({})
vm.runInNewContext(
  source +
    "\nthis.M = { dayStartMs: dayStartMs, dayKey: dayKey, normalizeSearchPrs: normalizeSearchPrs," +
    " normalizeSearchIssues: normalizeSearchIssues, normalizeSearchCommits: normalizeSearchCommits," +
    " normalizeLocalCommits: normalizeLocalCommits," +
    " mergeItems: mergeItems, groupByRepo: groupByRepo, counts: counts," +
    " updateStateCache: updateStateCache, weekStrip: weekStrip, markdownRecap: markdownRecap," +
    " recapFilePath: recapFilePath }",
  ctx
)

const fixture = (name) => readFileSync(join(root, "tests", "fixtures", name), "utf8")


const pad2 = (n) => (n < 10 ? "0" : "") + n
const M = {}
for (const [name, fn] of Object.entries(ctx.M)) {
  // Objects created inside the vm belong to another realm; node's strict
  // deepEqual compares prototypes, so lift every result into this realm.
  M[name] = (...args) => structuredClone(fn(...args))
}
const keyFor = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`
const daysAgoKey = (n) => {
  const d = new Date()
  d.setDate(d.getDate() - n)
  return keyFor(d)
}

const REAL_PRS = fixture("search-prs.json")
const REAL_ISSUES = fixture("search-issues.json")
const REAL_COMMITS = fixture("search-commits.json")

test("Model.js stays a plain script: no module syntax, no engine references", () => {
  assert.ok(!/^\s*(import|export)\s/m.test(source), "no import/export statements")
  assert.ok(!/\bQt\b/.test(source), "no Qt references")
})

// ---- dayStartMs / dayKey -------------------------------------------------

test("dayStartMs: 02:00 local with 04:00 boundary starts yesterday at 04:00", () => {
  const now = new Date(2026, 7, 21, 2, 0, 0).getTime()
  const expected = new Date(2026, 7, 20, 4, 0, 0).getTime()
  assert.equal(M.dayStartMs(now, "04:00"), expected)
})

test("dayStartMs: 05:00 local with 04:00 boundary starts today at 04:00", () => {
  const now = new Date(2026, 7, 21, 5, 0, 0).getTime()
  const expected = new Date(2026, 7, 21, 4, 0, 0).getTime()
  assert.equal(M.dayStartMs(now, "04:00"), expected)
})

test("dayStartMs: exact boundary moment belongs to today's logical day", () => {
  const now = new Date(2026, 7, 21, 4, 0, 0).getTime()
  assert.equal(M.dayStartMs(now, "04:00"), now)
})

test("dayStartMs: invalid boundaries fall back to local midnight", () => {
  const now = new Date(2026, 7, 21, 15, 30, 0).getTime()
  const midnight = new Date(2026, 7, 21, 0, 0, 0).getTime()
  for (const bad of ["25:00", "12:60", "7:00", "0400", "ab:cd", "", null, undefined]) {
    assert.equal(M.dayStartMs(now, bad), midnight, `boundary ${JSON.stringify(bad)}`)
  }
})

test("dayStartMs: boundary crossing month end rolls back a calendar day", () => {
  const now = new Date(2023, 2, 1, 2, 0, 0).getTime() // March 1st, 02:00
  const expected = new Date(2023, 1, 28, 4, 0, 0).getTime() // Feb 28
  assert.equal(M.dayStartMs(now, "04:00"), expected)
})

test("dayKey: pre-boundary timestamp maps to the previous calendar date", () => {
  const early = new Date(2026, 7, 21, 2, 0, 0).getTime()
  const atBoundary = new Date(2026, 7, 21, 4, 0, 0).getTime()
  assert.equal(M.dayKey(early, "04:00"), "2026-08-20")
  assert.equal(M.dayKey(atBoundary, "04:00"), "2026-08-21")
  assert.equal(M.dayKey(early), "2026-08-21")
})

test("dayKey: invalid input yields empty key without throwing", () => {
  assert.equal(M.dayKey(NaN, "04:00"), "")
  assert.equal(M.dayKey(undefined), "")
})

// ---- normalizeSearchPrs / normalizeSearchIssues --------------------------

test("normalizeSearchPrs: real /search/issues fixture parses to contract items", () => {
  const raw = JSON.parse(REAL_PRS)
  const items = M.normalizeSearchPrs(REAL_PRS)
  assert.equal(items.length, raw.items.length)
  for (const item of items) {
    assert.equal(item.type, "pr")
    assert.equal(item.sha, null)
    assert.match(item.repo, /^[\w.-]+\/[\w.-]+$/, "owner/name from repository_url tail")
    assert.match(item.url, /^https:\/\/github\.com\//)
    assert.equal(typeof item.ts, "number")
    assert.ok(Number.isFinite(item.ts))
  }
  const first = raw.items[0]
  assert.deepEqual(items[0], {
    type: "pr",
    repo: first.repository_url.slice(first.repository_url.indexOf("/repos/") + 7),
    title: first.title,
    url: first.html_url,
    ts: Date.parse(first.pull_request.merged_at || first.closed_at || first.updated_at),
    sha: null,
  })
})

test("normalizeSearchPrs: merged_at wins over closed_at/updated_at; missing pull_request block falls back", () => {
  const items = M.normalizeSearchPrs(fixture("search-prs.synthetic.json"))
  assert.equal(items.length, 3)
  assert.equal(items[0].ts, Date.parse("2026-08-21T09:00:00Z"), "merged_at beats later closed_at/updated_at")
  assert.equal(items[0].repo, "acme/widgets")
  assert.equal(items[1].ts, Date.parse("2026-08-21T08:00:00Z"), "no pull_request block -> closed_at")
  assert.equal(items[2].ts, Date.parse("2026-08-21T07:00:00Z"), "open PR -> updated_at")
})

test("normalizeSearchPrs: empty body, malformed JSON, array body, null input all yield []", () => {
  assert.deepEqual(M.normalizeSearchPrs(fixture("search-empty.json")), [])
  assert.deepEqual(M.normalizeSearchPrs(fixture("malformed.json")), [])
  assert.deepEqual(M.normalizeSearchPrs("[]"), [])
  assert.deepEqual(M.normalizeSearchPrs('{"total_count": 0}'), [])
  assert.deepEqual(M.normalizeSearchPrs(""), [])
  assert.deepEqual(M.normalizeSearchPrs(null), [])
})

test("normalizeSearchPrs: items without timestamps dropped, missing fields tolerated", () => {
  const items = M.normalizeSearchPrs(fixture("search-prs.missing.json"))
  assert.equal(items.length, 2)
  assert.deepEqual(items[0], {
    type: "pr",
    repo: "",
    title: "No repository_url",
    url: "https://github.com/x/y/pull/2",
    ts: Date.parse("2026-08-21T08:00:00Z"),
    sha: null,
  })
  assert.equal(items[1].title, "No html_url either")
  assert.equal(items[1].url, null)
  assert.equal(items[1].repo, "x/y")
})

test("normalizeSearchIssues: real fixture parses; type is issue", () => {
  const raw = JSON.parse(REAL_ISSUES)
  const items = M.normalizeSearchIssues(REAL_ISSUES)
  assert.equal(items.length, raw.items.length)
  for (const item of items) {
    assert.equal(item.type, "issue")
    assert.equal(item.sha, null)
    assert.match(item.repo, /^[\w.-]+\/[\w.-]+$/)
  }
})

test("normalizeSearchIssues: repository_url variants and closed_at precedence over updated_at", () => {
  const items = M.normalizeSearchIssues(fixture("search-issues.variants.json"))
  assert.equal(items.length, 3)
  assert.equal(items[0].repo, "joshuaswarren/remnic")
  assert.equal(items[0].ts, Date.parse("2026-08-21T09:00:00Z"), "closed_at beats updated_at")
  assert.equal(items[1].repo, "", "repository_url without /repos/ yields empty repo")
  assert.equal(items[2].repo, "", "missing repository_url yields empty repo")
  assert.deepEqual(M.normalizeSearchIssues(fixture("search-empty.json")), [])
  assert.deepEqual(M.normalizeSearchIssues(fixture("malformed.json")), [])
})

// ---- normalizeSearchCommits ------------------------------------------------

test("normalizeSearchCommits: real /search/commits fixture parses to contract items", () => {
  const raw = JSON.parse(REAL_COMMITS)
  const items = M.normalizeSearchCommits(REAL_COMMITS)
  assert.equal(items.length, raw.items.length)
  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    const entry = raw.items[i]
    assert.equal(item.type, "commit")
    assert.equal(item.sha, entry.sha)
    assert.equal(item.url, entry.html_url)
    assert.equal(item.repo, entry.repository.full_name)
    assert.equal(item.title, entry.commit.message.split("\n")[0])
    assert.equal(typeof item.ts, "number")
    assert.ok(Number.isFinite(item.ts))
  }
})

test("normalizeSearchCommits: numeric UTC offsets in author dates parse exactly", () => {
  const items = M.normalizeSearchCommits(fixture("search-commits.synthetic.json"))
  const offsetTs = Date.parse("2026-08-21T06:28:55.000-05:00")
  assert.ok(Number.isFinite(offsetTs), "sanity: Date.parse accepts the offset form")
  assert.equal(offsetTs, Date.parse("2026-08-21T11:28:55.000Z"), "sanity: offset equals its UTC instant")
  assert.equal(items[0].ts, offsetTs)
  assert.equal(items[0].title, "Add day-boundary math", "first message line only")
})

test("normalizeSearchCommits: sha-less and date-less items dropped; repository fallbacks", () => {
  const items = M.normalizeSearchCommits(fixture("search-commits.synthetic.json"))
  assert.equal(items.length, 3, "missing sha and missing author date each drop an item")
  assert.equal(items[1].repo, "joshuaswarren/allward", "repository_url tail when no repository object")
  assert.equal(items[2].repo, "", "neither repository nor repository_url")
  assert.deepEqual(M.normalizeSearchCommits(fixture("search-empty.json")), [])
  assert.deepEqual(M.normalizeSearchCommits(fixture("malformed.json")), [])
  assert.deepEqual(M.normalizeSearchCommits("[]"), [])
  assert.deepEqual(M.normalizeSearchCommits(null), [])
})

// ---- normalizeLocalCommits -------------------------------------------------

test("normalizeLocalCommits: TSV lines parse; junk lines skipped silently", () => {
  const tsv = [
    "aaa111\t1787000000\tFix one\t/home/user/src/acme-widgets",
    "bbb222\t1787000060\tFix two\t/home/joshuawarren/src/remnic",
    "",
    "short-line-without-tabs",
    "ccc333\tnotanumber\tBad epoch\t/x",
    "ddd444\t1787000120\tFix three\t/x/y",
  ].join("\n")
  assert.deepEqual(M.normalizeLocalCommits(tsv), [
    {
      type: "commit",
      repo: "/home/user/src/acme-widgets",
      title: "Fix one",
      url: null,
      ts: 1787000000000,
      sha: "aaa111",
    },
    {
      type: "commit",
      repo: "/home/joshuawarren/src/remnic",
      title: "Fix two",
      url: null,
      ts: 1787000060000,
      sha: "bbb222",
    },
    {
      type: "commit",
      repo: "/x/y",
      title: "Fix three",
      url: null,
      ts: 1787000120000,
      sha: "ddd444",
    },
  ])
  assert.deepEqual(M.normalizeLocalCommits(""), [])
  assert.deepEqual(M.normalizeLocalCommits(null), [])
})

// ---- mergeItems -------------------------------------------------------------

test("mergeItems: drops pre-day-start items, keeps boundary-equal ones", () => {
  const start = 1000
  const old = { type: "commit", repo: "a/b", title: "old", url: null, ts: 999, sha: "old" }
  const edge = { type: "commit", repo: "a/b", title: "edge", url: null, ts: 1000, sha: "edge" }
  const kept = M.mergeItems([[old, edge]], start)
  assert.deepEqual(kept, [edge])
})

test("mergeItems: force-push duplicate sha counts once, newest ts wins", () => {
  const dup = (ts) => ({
    type: "commit", repo: "a/b", title: "t", url: null, ts, sha: "same-sha",
  })
  const merged = M.mergeItems([[dup(2000), dup(3000)]], 0)
  assert.equal(merged.length, 1)
  assert.equal(merged[0].ts, 3000)
})

test("mergeItems: same sha from search-commits and local scan dedups to one", () => {
  const remote = {
    type: "commit", repo: "a/b", title: "from search",
    url: "https://github.com/a/b/commit/abc", ts: 2000, sha: "abc",
  }
  const local = {
    type: "commit", repo: "/home/x/src/b", title: "from local",
    url: null, ts: 1000, sha: "abc",
  }
  const merged = M.mergeItems([[remote], [local]], 0)
  assert.equal(merged.length, 1)
  assert.equal(merged[0].title, "from search")
})

test("mergeItems: prs/issues dedup by url; result sorted newest first", () => {
  const pr = (ts, n) => ({
    type: "pr", repo: "a/b", title: `pr${n}`, url: `https://github.com/a/b/pull/${n}`, ts, sha: null,
  })
  const issue = (ts, n) => ({
    type: "issue", repo: "a/b", title: `i${n}`, url: `https://github.com/a/b/issues/${n}`, ts, sha: null,
  })
  const merged = M.mergeItems([[pr(100, 1), pr(300, 1)], [issue(200, 5)]], 0)
  assert.deepEqual(
    merged.map((i) => i.title),
    ["pr1", "i5"]
  )
})

test("mergeItems: empty and malformed list-of-lists yield []", () => {
  assert.deepEqual(M.mergeItems([], 0), [])
  assert.deepEqual(M.mergeItems([[], null, "nope"], 0), [])
  assert.deepEqual(M.mergeItems(null, 0), [])
})

// ---- groupByRepo --------------------------------------------------------------

test("groupByRepo: groups ordered by newest item, inner items keep order", () => {
  const mk = (repo, ts, title) => ({ type: "commit", repo, title, url: null, ts, sha: title })
  const groups = M.groupByRepo([mk("a/one", 5, "a5"), mk("b/two", 9, "b9"), mk("a/one", 1, "a1")])
  assert.deepEqual(
    groups.map((g) => g.repo),
    ["b/two", "a/one"]
  )
  assert.deepEqual(
    groups[1].items.map((i) => i.title),
    ["a5", "a1"]
  )
  assert.deepEqual(M.groupByRepo([]), [])
  assert.deepEqual(M.groupByRepo(null), [])
})

// ---- counts --------------------------------------------------------------------

test("counts: mixed types counted, unknown types ignored by total", () => {
  const items = [
    { type: "commit" }, { type: "commit" }, { type: "pr" }, { type: "issue" }, { type: "weird" }, null,
  ]
  assert.deepEqual(M.counts(items), { commits: 2, prs: 1, issues: 1, total: 4 })
  assert.deepEqual(M.counts([]), { commits: 0, prs: 0, issues: 0, total: 0 })
  assert.deepEqual(M.counts(null), { commits: 0, prs: 0, issues: 0, total: 0 })
})

// ---- updateStateCache -------------------------------------------------------------

test("updateStateCache: empty text starts fresh and stores normalized counts", () => {
  const today = daysAgoKey(0)
  const state = M.updateStateCache("", today, { commits: 2, prs: 1, issues: 0, total: 3 })
  assert.deepEqual(state, { version: 1, days: { [today]: { commits: 2, prs: 1, issues: 0, total: 3 } } })
})

test("updateStateCache: prior days survive, new day added", () => {
  const yesterday = daysAgoKey(1)
  const today = daysAgoKey(0)
  const seed = JSON.stringify({ version: 1, days: { [yesterday]: { commits: 1, prs: 0, issues: 0, total: 1 } } })
  const state = M.updateStateCache(seed, today, { commits: 0, prs: 1, issues: 1, total: 2 })
  assert.deepEqual(state.days[yesterday], { commits: 1, prs: 0, issues: 0, total: 1 })
  assert.deepEqual(state.days[today], { commits: 0, prs: 1, issues: 1, total: 2 })
  assert.equal(Object.keys(state.days).length, 2)
})

test("updateStateCache: prunes keys older than 14 days, keeps 13", () => {
  const old20 = daysAgoKey(20)
  const old13 = daysAgoKey(13)
  const old1 = daysAgoKey(1)
  const today = daysAgoKey(0)
  const seed = JSON.stringify({
    version: 1,
    days: {
      [old20]: { commits: 9, prs: 9, issues: 9, total: 9 },
      [old13]: { commits: 1, prs: 1, issues: 1, total: 3 },
      [old1]: { commits: 2, prs: 0, issues: 0, total: 2 },
    },
  })
  const state = M.updateStateCache(seed, today, { commits: 1, prs: 0, issues: 0, total: 1 })
  assert.equal(state.days[old20], undefined)
  assert.deepEqual(state.days[old13], { commits: 1, prs: 1, issues: 1, total: 3 })
  assert.ok(state.days[old1])
  assert.ok(state.days[today])
})

test("updateStateCache: corrupt text and null degrade to a fresh state", () => {
  const today = daysAgoKey(0)
  for (const bad of ["{not json", "[1,2,3]", '"a string"', null]) {
    const state = M.updateStateCache(bad, today, { commits: 1, prs: 1, issues: 1, total: 3 })
    assert.deepEqual(Object.keys(state.days), [today])
    assert.equal(state.version, 1)
  }
})

// ---- weekStrip ----------------------------------------------------------------------

test("weekStrip: seven logical days oldest first, missing days count 0, today flagged", () => {
  const today = daysAgoKey(0)
  const state = M.updateStateCache("", today, { commits: 3, prs: 2, issues: 0, total: 5 })
  const strip = M.weekStrip(state, today, "00:00")
  assert.equal(strip.length, 7)
  assert.deepEqual(
    strip.map((d) => d.key),
    [6, 5, 4, 3, 2, 1, 0].map(daysAgoKey)
  )
  assert.deepEqual(
    strip.map((d) => d.count),
    [0, 0, 0, 0, 0, 0, 5]
  )
  assert.deepEqual(
    strip.map((d) => d.isToday),
    [false, false, false, false, false, false, true]
  )
})

test("weekStrip: labels are locale-independent single letters", () => {
  const today = daysAgoKey(0)
  const strip = M.weekStrip({ days: {} }, today, "00:00")
  const letters = ["S", "M", "T", "W", "T", "F", "S"]
  const expected = []
  for (let back = 6; back >= 0; back--) {
    const d = new Date()
    d.setDate(d.getDate() - back)
    expected.push(letters[d.getDay()])
  }
  assert.deepEqual(strip.map((d) => d.label), expected)
})

test("weekStrip: non-midnight boundary keeps the same day keys", () => {
  const today = daysAgoKey(0)
  const strip = M.weekStrip({ days: {} }, today, "04:00")
  assert.deepEqual(
    strip.map((d) => d.key),
    [6, 5, 4, 3, 2, 1, 0].map(daysAgoKey)
  )
})

test("weekStrip: corrupt state object and bad todayKey degrade safely", () => {
  const today = daysAgoKey(0)
  assert.equal(M.weekStrip({}, today, "00:00").length, 7)
  assert.equal(M.weekStrip(null, today, "00:00").length, 7)
  assert.deepEqual(M.weekStrip({ days: {} }, "garbage", "00:00"), [])
})


// ---- recapFilePath ---------------------------------------------------------------------

test("recapFilePath: valid absolute dir and day key", () => {
  assert.equal(M.recapFilePath("/recaps", "2026-08-21"), "/recaps/2026-08-21.md")
})

test("recapFilePath: strips trailing slash on dir", () => {
  assert.equal(M.recapFilePath("/a/b/", "2026-08-21"), "/a/b/2026-08-21.md")
})

test("recapFilePath: dots in segment names are allowed", () => {
  assert.equal(M.recapFilePath("/a/b.c/d", "2026-08-21"), "/a/b.c/d/2026-08-21.md")
})

test("recapFilePath: rejects relative dir", () => {
  assert.equal(M.recapFilePath("recaps/out", "2026-08-21"), "")
})

test("recapFilePath: rejects empty or whitespace-only dir", () => {
  assert.equal(M.recapFilePath("", "2026-08-21"), "")
  assert.equal(M.recapFilePath("   ", "2026-08-21"), "")
  assert.equal(M.recapFilePath("\t", "2026-08-21"), "")
})

test("recapFilePath: rejects dot and dot-dot path segments", () => {
  assert.equal(M.recapFilePath("/a/../b", "2026-08-21"), "")
  assert.equal(M.recapFilePath("/a/./b", "2026-08-21"), "")
  assert.equal(M.recapFilePath("/safe/..", "2026-08-21"), "")
})

test("recapFilePath: rejects malformed or empty day keys", () => {
  assert.equal(M.recapFilePath("/recaps", "2026-8-21"), "")
  assert.equal(M.recapFilePath("/recaps", "garbage"), "")
  assert.equal(M.recapFilePath("/recaps", ""), "")
})

test("recapFilePath: null and undefined inputs yield empty string", () => {
  assert.equal(M.recapFilePath(null, "2026-08-21"), "")
  assert.equal(M.recapFilePath("/recaps", null), "")
  assert.equal(M.recapFilePath(undefined, "2026-08-21"), "")
  assert.equal(M.recapFilePath("/recaps", undefined), "")
})

// ---- markdownRecap ---------------------------------------------------------------------

test("markdownRecap: grouped sections, linked rows, bare rows for null urls", () => {
  const items = [
    {
      type: "commit", repo: "a/one", title: "newest commit",
      url: "https://github.com/a/one/commit/abc", ts: 300, sha: "abc",
    },
    {
      type: "commit", repo: "/home/x/src/local", title: "local only commit",
      url: null, ts: 200, sha: "def",
    },
    {
      type: "pr", repo: "a/one", title: "older pr",
      url: "https://github.com/a/one/pull/9", ts: 100, sha: null,
    },
  ]
  assert.equal(
    M.markdownRecap(items, "2026-08-21"),
    [
      "# Shipped 2026-08-21",
      "",
      "## a/one",
      "- [newest commit](https://github.com/a/one/commit/abc)",
      "- [older pr](https://github.com/a/one/pull/9)",
      "",
      "## /home/x/src/local",
      "- local only commit",
      "",
    ].join("\n")
  )
})

test("markdownRecap: escapes titles and repo names, drops non-http urls", () => {
  const items = [
    {
      type: "pr", repo: "evil/one", title: "fix](https://evil.com) ![beacon](https://evil.com/x.gif)",
      url: "https://github.com/evil/one/pull/1", ts: 100, sha: null,
    },
    {
      type: "commit", repo: "a/one", title: "javascript:alert(1)",
      url: "javascript:alert(1)", ts: 90, sha: "abc",
    },
  ]
  const recap = M.markdownRecap(items, "2026-08-21")
  // The title's brackets are escaped, so the whole thing is one link whose
  // target is the github.com url; no image syntax and no evil.com link form.
  assert.ok(recap.includes("\\](https://evil.com)"))
  assert.ok(!recap.includes("![beacon]"))
  assert.ok(!recap.includes("](javascript:"))
  assert.ok(recap.includes("- javascript:alert(1)"))
})

test("markdownRecap: empty day renders the zero state", () => {
  assert.equal(M.markdownRecap([], "2026-08-21"), "# Shipped 2026-08-21\nNothing shipped.\n")
  assert.equal(M.markdownRecap(null, "2026-08-21"), "# Shipped 2026-08-21\nNothing shipped.\n")
})

// ---- cross-function smoke ------------------------------------------------------------------

test("full pipeline: fixtures through merge, group, counts, recap without throwing", () => {
  const start = M.dayStartMs(Date.now(), "00:00")
  const prs = M.normalizeSearchPrs(REAL_PRS)
  const issues = M.normalizeSearchIssues(REAL_ISSUES)
  const commits = M.normalizeSearchCommits(REAL_COMMITS)
  const local = M.normalizeLocalCommits("eef999\t1787350000\tlocal scan commit\t/home/joshuawarren/src/remnic")
  const merged = M.mergeItems([prs, issues, commits, local], 0)
  const groups = M.groupByRepo(merged)
  const c = M.counts(merged)
  assert.equal(c.total, merged.length)
  assert.equal(c.total, groups.reduce((n, g) => n + g.items.length, 0))
  assert.ok(M.markdownRecap(merged, "today").startsWith("# Shipped today"))
})
