// Pure data logic for the Shiplog bar widget: day-boundary math, GitHub REST
// search parsing, dedup, grouping, week-strip cache, and the Markdown
// recap. Plain script, no module syntax: the same file loads as a QML
// JavaScript resource for the panel and runs under node:vm for unit tests.

var MS_PER_DAY = 86400000

// Single-letter weekday labels, index matching Date.getDay() (0 = Sunday).
var WEEKDAY_LETTERS = ["S", "M", "T", "W", "T", "F", "S"]

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// "HH:MM" with 00-23 hours and 00-59 minutes; anything else is midnight.
function parseBoundary(boundary) {
  var m = /^(\d{2}):(\d{2})$/.exec(String(boundary === undefined || boundary === null ? "" : boundary))
  if (!m) return { h: 0, m: 0 }
  var h = Number(m[1]), min = Number(m[2])
  if (h > 23 || min > 59) return { h: 0, m: 0 }
  return { h: h, m: min }
}

function formatDayKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

// Local calendar date of a "YYYY-MM-DD" string, or null when malformed.
function parseDayKey(key) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(key === undefined || key === null ? "" : key))
  if (!m) return null
  var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
  return isNaN(d.getTime()) ? null : d
}

// Start of the logical day containing nowMs. When the wall clock has not yet
// reached the boundary (night owl rolling past midnight), the logical day
// began yesterday at the boundary.
function dayStartMs(nowMs, boundary) {
  var ms = Number(nowMs)
  if (!isFinite(ms)) return NaN
  var b = parseBoundary(boundary)
  var d = new Date(ms)
  var start = new Date(d.getFullYear(), d.getMonth(), d.getDate(), b.h, b.m, 0, 0)
  if (start.getTime() > ms) {
    start = new Date(d.getFullYear(), d.getMonth(), d.getDate() - 1, b.h, b.m, 0, 0)
  }
  return start.getTime()
}

function dayKey(tsMs, boundary) {
  var start = dayStartMs(tsMs, boundary)
  if (isNaN(start)) return ""
  return formatDayKey(new Date(start))
}

function tsFromIso(value) {
  if (value === undefined || value === null || value === "") return NaN
  var t = Date.parse(String(value))
  return isNaN(t) ? NaN : t
}

// JSON.parse that yields a REST search body's items[] or nothing; every
// consumer treats garbage as "no data" and keeps the last good state
// instead of throwing.
function safeParseSearchItems(jsonText) {
  if (typeof jsonText !== "string") return []
  try {
    var parsed = JSON.parse(jsonText)
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return []
    return Array.isArray(parsed.items) ? parsed.items : []
  } catch (e) {
    return []
  }
}

// "https://api.github.com/repos/OWNER/NAME" -> "OWNER/NAME"; anything else "".
function repoFromRepositoryUrl(url) {
  var text = String(url === undefined || url === null ? "" : url)
  var at = text.indexOf("/repos/")
  return at === -1 ? "" : text.slice(at + 7)
}

// /search/issues response body: one shared item shape for PRs and issues.
// ts falls back merged_at -> closed_at -> updated_at; an item with no
// parsable timestamp is dropped rather than shipped with NaN.
function normalizeSearchIssueItems(jsonText, type) {
  var list = safeParseSearchItems(jsonText)
  var out = []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || typeof entry !== "object") continue
    var ts = NaN
    if (type === "pr" && entry.pull_request && typeof entry.pull_request === "object") {
      ts = tsFromIso(entry.pull_request.merged_at)
    }
    if (isNaN(ts)) ts = tsFromIso(entry.closed_at)
    if (isNaN(ts)) ts = tsFromIso(entry.updated_at)
    if (isNaN(ts)) continue
    out.push({
      type: type,
      repo: repoFromRepositoryUrl(entry.repository_url),
      title: String(entry.title === undefined || entry.title === null ? "" : entry.title),
      url: entry.html_url ? String(entry.html_url) : null,
      ts: ts,
      sha: null
    })
  }
  return out
}

function normalizeSearchPrs(jsonText) {
  return normalizeSearchIssueItems(jsonText, "pr")
}

function normalizeSearchIssues(jsonText) {
  return normalizeSearchIssueItems(jsonText, "issue")
}

// /search/commits response body. Commit search indexes default branches
// only; any-branch and non-GitHub coverage comes from the local source.
function normalizeSearchCommits(jsonText) {
  var list = safeParseSearchItems(jsonText)
  var out = []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || typeof entry !== "object") continue
    var sha = String(entry.sha || "")
    if (!sha) continue
    var commit = entry.commit && typeof entry.commit === "object" ? entry.commit : null
    var ts = NaN
    if (commit && commit.author && typeof commit.author === "object") {
      ts = tsFromIso(commit.author.date)
    }
    if (isNaN(ts)) continue
    var message = commit ? String(commit.message === undefined || commit.message === null ? "" : commit.message) : ""
    var repo = ""
    if (entry.repository && typeof entry.repository === "object" && entry.repository.full_name) {
      repo = String(entry.repository.full_name)
    } else {
      repo = repoFromRepositoryUrl(entry.repository_url)
    }
    out.push({
      type: "commit",
      repo: repo,
      title: message.split("\n")[0],
      url: entry.html_url ? String(entry.html_url) : null,
      ts: ts,
      sha: sha
    })
  }
  return out
}

// local-commits.sh output: one line per commit, tab-separated
// sha, epoch seconds, subject, absolute repo path. The subject itself may
// contain tabs, so the repo path is the LAST field and the subject is
// everything between the epoch and it.
function normalizeLocalCommits(tsvText) {
  var lines = String(tsvText === undefined || tsvText === null ? "" : tsvText).split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    var parts = lines[i].split("\t")
    if (parts.length < 4) continue
    var epoch = Number(parts[1])
    if (!parts[0] || !isFinite(epoch)) continue
    out.push({
      type: "commit",
      repo: parts[parts.length - 1],
      title: parts.slice(2, parts.length - 1).join("\t"),
      url: null,
      ts: epoch * 1000,
      sha: parts[0]
    })
  }
  return out
}

function stableSortByTsDesc(items) {
  var indexed = []
  for (var i = 0; i < items.length; i++) indexed.push({ item: items[i], i: i })
  indexed.sort(function (a, b) { return b.item.ts - a.item.ts || a.i - b.i })
  var out = []
  for (var k = 0; k < indexed.length; k++) out.push(indexed[k].item)
  return out
}

// Flatten, keep only items at or after the logical day start, dedup commits
// by sha and prs/issues by url (first occurrence wins), newest first.
function mergeItems(listOfLists, dayStartMs2) {
  var lists = listOfLists || []
  var flat = []
  for (var i = 0; i < lists.length; i++) {
    var list = lists[i]
    if (!list || typeof list.length !== "number") continue
    for (var k = 0; k < list.length; k++) {
      var item = list[k]
      if (!item || typeof item.ts !== "number" || !isFinite(item.ts)) continue
      if (item.ts < dayStartMs2) continue
      flat.push(item)
    }
  }
  var sorted = stableSortByTsDesc(flat)
  var out = []
  var seenSha = {}, seenUrl = {}
  for (var s = 0; s < sorted.length; s++) {
    var it = sorted[s]
    if (it.type === "commit" && it.sha) {
      if (seenSha[it.sha]) continue
      seenSha[it.sha] = true
    } else if (it.url) {
      if (seenUrl[it.url]) continue
      seenUrl[it.url] = true
    }
    out.push(it)
  }
  return out
}

// Groups keyed by repo, ordered by each group's newest item; items keep their
// incoming (newest-first) order.
function groupByRepo(items) {
  var list = items || []
  var order = [], byRepo = {}
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (!item) continue
    var repo = String(item.repo === undefined || item.repo === null ? "" : item.repo)
    if (!Object.prototype.hasOwnProperty.call(byRepo, repo)) {
      byRepo[repo] = []
      order.push(repo)
    }
    byRepo[repo].push(item)
  }
  var groups = []
  for (var g = 0; g < order.length; g++) {
    groups.push({ repo: order[g], items: byRepo[order[g]] })
  }
  groups.sort(function (a, b) {
    return newestTs(b.items) - newestTs(a.items) || order.indexOf(a.repo) - order.indexOf(b.repo)
  })
  return groups
}

function newestTs(items) {
  var newest = -Infinity
  for (var i = 0; i < items.length; i++) {
    if (typeof items[i].ts === "number" && items[i].ts > newest) newest = items[i].ts
  }
  return newest
}

function counts(items) {
  var list = items || []
  var c = { commits: 0, prs: 0, issues: 0, total: 0 }
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (!item) continue
    if (item.type === "commit") c.commits++
    else if (item.type === "pr") c.prs++
    else if (item.type === "issue") c.issues++
    else continue
    c.total++
  }
  return c
}

function cacheNumber(value) {
  var n = Number(value)
  return isFinite(n) ? n : 0
}

// Tolerant StateFile update: empty or corrupt text starts fresh, the day's
// counts are written, and anything older than 14 days is dropped.
function updateStateCache(stateText, key, cnts) {
  var state = null
  if (typeof stateText === "string" && stateText !== "") {
    var parsed = safeParseState(stateText)
    if (parsed) state = parsed
  }
  if (!state) state = { version: 1, days: {} }
  state.version = 1
  if (typeof key === "string" && /^\d{4}-\d{2}-\d{2}$/.test(key)) {
    state.days[key] = {
      commits: cacheNumber(cnts && cnts.commits),
      prs: cacheNumber(cnts && cnts.prs),
      issues: cacheNumber(cnts && cnts.issues),
      total: cacheNumber(cnts && cnts.total)
    }
    var cutoff = parseDayKey(key)
    if (cutoff) {
      cutoff.setDate(cutoff.getDate() - 14)
      var cutoffKey = formatDayKey(cutoff)
      for (var day in state.days) {
        if (Object.prototype.hasOwnProperty.call(state.days, day) && day < cutoffKey) delete state.days[day]
      }
    }
  }
  return state
}

function safeParseState(stateText) {
  try {
    var parsed = JSON.parse(stateText)
    if (parsed && typeof parsed === "object" &&
        parsed.days && typeof parsed.days === "object") {
      return { version: 1, days: parsed.days }
    }
  } catch (e) {}
  return null
}

// The seven logical days ending at todayKey, oldest first. Day keys step back
// from todayKey's boundary instant so a non-midnight boundary stays aligned.
function weekStrip(stateObj, todayKey, boundary) {
  var days = {}
  if (stateObj && typeof stateObj === "object" &&
      stateObj.days && typeof stateObj.days === "object") {
    days = stateObj.days
  }
  var base = parseDayKey(todayKey)
  if (!base) return []
  var b = parseBoundary(boundary)
  var out = []
  for (var back = 6; back >= 0; back--) {
    var d = new Date(base.getFullYear(), base.getMonth(), base.getDate() - back, b.h, b.m, 0, 0)
    var key = formatDayKey(d)
    var day = days[key]
    var count = (day && typeof day.total === "number" && isFinite(day.total)) ? day.total : 0
    out.push({ key: key, label: WEEKDAY_LETTERS[d.getDay()], count: count, isToday: key === todayKey })
  }
  return out
}

// "Copy day as Markdown" recap: header, one section per repo, linked rows
// (bare rows for local-only commits, whose url is null).
function markdownRecap(items, dateLabel) {
  var lines = ["# Shipped " + String(dateLabel === undefined || dateLabel === null ? "" : dateLabel)]
  var groups = groupByRepo(items)
  if (groups.length === 0) {
    lines.push("Nothing shipped.")
    return lines.join("\n") + "\n"
  }
  for (var g = 0; g < groups.length; g++) {
    lines.push("")
    lines.push("## " + groups[g].repo)
    for (var i = 0; i < groups[g].items.length; i++) {
      var item = groups[g].items[i]
      if (item.url) lines.push("- [" + item.title + "](" + item.url + ")")
      else lines.push("- " + item.title)
    }
  }
  return lines.join("\n") + "\n"
}
