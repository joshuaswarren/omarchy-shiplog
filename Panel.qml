import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The day log. This file owns every subprocess and all mutable state; Model.js
// owns every parse and every derivation. Nothing here builds a shell command:
// each Process takes an argument array, so no configured string is ever
// interpreted by a shell.
Panel {
  id: root
  moduleName: "io.github.joshuaswarren.shiplog"
  ipcTarget: "io.github.joshuaswarren.shiplog"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot, BarWidget.qml, and not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Two steps, far enough apart to be two steps: 1.4 is the kit's secondary
  // (PanelSectionHeader.qml:14, PanelHero.qml:22) and 1.9 its tertiary
  // (clock/Panel.qml:580, 639). At 1.6 the pair differed by 14% and read as
  // one muddled level, which left row times, split labels and spent week
  // days all sitting at the same weight as the counts they qualify.
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color dimmer: Qt.darker(foreground, 1.9)

  // ---- Settings. Values can arrive from the settings form (typed) or from a
  //      hand-edited shell.json (anything), so every read is coerced.

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (value === true || value === false) return value
    var text = String(value).toLowerCase()
    if (text === "true" || text === "1" || text === "yes") return true
    if (text === "false" || text === "0" || text === "no") return false
    return fallback
  }

  function listSetting(name, fallback) {
    var value = setting(name, fallback)
    var list = Array.isArray(value) ? value : String(value).split(",")
    var out = []
    for (var i = 0; i < list.length; i++) {
      var entry = String(list[i]).replace(/^\s+|\s+$/g, "")
      if (entry !== "" && out.indexOf(entry) === -1) out.push(entry)
    }
    return out
  }

  readonly property var sources: {
    var requested = listSetting("sources", ["github"])
    var out = []
    for (var i = 0; i < requested.length; i++) {
      var name = requested[i].toLowerCase()
      if ((name === "github" || name === "local") && out.indexOf(name) === -1) out.push(name)
    }
    return out.length > 0 ? out : ["github"]
  }
  readonly property bool githubEnabled: sources.indexOf("github") !== -1
  readonly property bool localEnabled: sources.indexOf("local") !== -1

  readonly property bool countCommits: boolSetting("countCommits", true)
  readonly property bool countMergedPrs: boolSetting("countMergedPrs", true)
  readonly property bool countClosedIssues: boolSetting("countClosedIssues", true)

  readonly property int pollMinutes: Math.max(5, parseInt(setting("pollMinutes", 5), 10) || 5)
  readonly property string dayBoundary: String(setting("dayBoundary", "00:00"))

  // A leading ~ is the only expansion; the scan script receives finished
  // absolute paths as separate arguments.
  readonly property var localRepoDirs: {
    var configured = listSetting("localRepoDirs", ["~/src"])
    var home = Quickshell.env("HOME")
    var out = []
    for (var i = 0; i < configured.length; i++) {
      var dir = configured[i]
      if (dir === "~") dir = home
      else if (dir.indexOf("~/") === 0) dir = home + dir.substr(1)
      if (dir !== "" && out.indexOf(dir) === -1) out.push(dir)
    }
    return out
  }

  // Plugin source directory, so the bundled scan script can be invoked by
  // absolute path. Qt hands back a percent-encoded file URL.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    if (url.indexOf("localhost/") === 0) url = url.substring(9)
    try { url = decodeURIComponent(url) } catch (e) { }
    return url.replace(/\/+$/, "")
  }
  readonly property string localScript: pluginDir + "/scripts/local-commits.sh"

  // ---- Day window. Recomputed on refresh, on rollover, and when the
  //      configured boundary changes; a plain property because Date.now()
  //      cannot be a reactive binding.
  property real dayStartMs: Model.dayStartMs(Date.now(), "00:00")
  readonly property string todayKey: Model.dayKey(dayStartMs, dayBoundary)
  readonly property string dateLabel: Qt.formatDate(new Date(dayStartMs), "dddd d MMMM")

  onDayBoundaryChanged: {
    advanceDay()
    scheduleRollover()
    Qt.callLater(refresh)
  }

  // ---- Per-source last-good data. A failing fetch never clears its list, so
  //      the panel keeps showing the last good day while the warning dot
  //      explains what is stale.
  property var prItems: []
  property var issueItems: []
  property var commitItems: []
  property var localItems: []

  property bool prError: false
  property bool issueError: false
  property bool commitError: false
  property bool localError: false

  // Set once a usable body has been parsed, so a late non-zero exit cannot
  // overrule an answer that already arrived.
  property bool prResponded: false
  property bool issueResponded: false
  property bool commitResponded: false
  property bool localResponded: false

  property string login: ""
  property real lastGoodMs: 0

  readonly property bool githubFailing: githubEnabled
    && ((countMergedPrs && prError) || (countClosedIssues && issueError) || (countCommits && commitError))
  readonly property bool localFailing: localEnabled && countCommits && localError

  readonly property string errorSummary: {
    var failing = []
    if (githubFailing) failing.push("GitHub")
    if (localFailing) failing.push("Local repositories")
    if (failing.length === 0) return ""
    var since = lastGoodMs > 0
      ? " \u2014 showing last data from " + Qt.formatDateTime(new Date(lastGoodMs), "HH:mm")
      : ""
    return failing.join(" and ") + " unreachable" + since
  }
  readonly property bool hasError: errorSummary !== ""

  // ---- Derived view state. Model.js does the dedup, the day filter, the
  //      ordering and the grouping.
  readonly property var items: Model.mergeItems(activeLists(), dayStartMs) || []
  readonly property var todayCounts: Model.counts(items) || ({ commits: 0, prs: 0, issues: 0, total: 0 })
  readonly property int totalCount: Number(todayCounts.total) || 0
  readonly property string label: totalCount > 0 ? String(totalCount) : ""
  readonly property var groups: Model.groupByRepo(items) || []

  function activeLists() {
    var lists = []
    if (githubEnabled && countMergedPrs) lists.push(prItems)
    if (githubEnabled && countClosedIssues) lists.push(issueItems)
    if (githubEnabled && countCommits) lists.push(commitItems)
    if (localEnabled && countCommits) lists.push(localItems)
    return lists
  }

  // Flat view over the grouped rows, so one integer drives keyboard selection
  // across group boundaries.
  readonly property var flatItems: {
    var out = []
    for (var i = 0; i < groups.length; i++) {
      var entry = groups[i]
      if (!entry || !entry.items) continue
      for (var j = 0; j < entry.items.length; j++) out.push(entry.items[j])
    }
    return out
  }
  readonly property var groupOffsets: {
    var out = []
    var running = 0
    for (var i = 0; i < groups.length; i++) {
      out.push(running)
      running += groups[i] && groups[i].items ? groups[i].items.length : 0
    }
    return out
  }

  property int selectedIndex: -1
  // Row tops within the list column, reported by the rows themselves. Plain
  // object, mutated in place: nothing binds to it, it only feeds scrolling.
  property var rowGeometry: ({})

  onItemsChanged: {
    rowGeometry = ({})
    var flatCount = flatItems ? flatItems.length : 0
    if (selectedIndex >= flatCount) selectedIndex = flatCount - 1
  }

  // ---- Week strip cache. The file is the base; today's cell always comes
  //      from the live counts, so the strip is never a poll behind.
  property string stateText: ""
  readonly property var stateObject: Model.updateStateCache(stateText, todayKey, todayCounts)
  readonly property var weekCells: Model.weekStrip(stateObject, todayKey, dayBoundary) || []

  readonly property string updatedLabel: lastGoodMs > 0
    ? Qt.formatDateTime(new Date(lastGoodMs), "HH:mm") : ""

  // ---- Lifecycle -----------------------------------------------------------

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  onOpenedChanged: if (opened) selectedIndex = -1

  // ---- Fetching ------------------------------------------------------------

  // The search window only has to cover the logical day; Model.mergeItems does
  // the exact local-day filtering. One day of slack absorbs every timezone.
  function searchSinceDate() {
    var start = isFinite(dayStartMs) ? dayStartMs : Date.now()
    return new Date(start - 86400000).toISOString().slice(0, 10)
  }

  // Any window move goes through advanceDay so the finished day is always
  // persisted under its own key first. This closes the wake-from-sleep race
  // where the poll timer's refresh could move the window before the pending
  // rollover timer had written yesterday's cell.
  function advanceDay() {
    var next = Model.dayStartMs(Date.now(), dayBoundary)
    if (!isFinite(next) || next === dayStartMs) return
    persistCounts()
    dayStartMs = next
    selectedIndex = -1
    scheduleRollover()
  }

  // The poll timer already floors at pollMinutes; this floor is for the IPC
  // path, which any same-user process can call in a tight loop and would
  // otherwise bypass the poll interval and hammer the API.
  property real lastIpcRefreshMs: 0

  function ipcRefresh() {
    var now = Date.now()
    if (now - lastIpcRefreshMs < 30000) return
    lastIpcRefreshMs = now
    refresh()
  }

  function refresh() {
    advanceDay()

    if (githubEnabled) {
      startGithubFetches()
    } else {
      prError = false
      issueError = false
      commitError = false
    }

    if (localEnabled && countCommits) startLocalFetch()
    else localError = false
  }

  function markFresh() {
    lastGoodMs = Date.now()
    stateSaveTimer.restart()
  }

  // Every GitHub source is one REST search. The path is composed here and
  // handed over as a single argument, so no shell ever sees it, and the only
  // variable parts are the resolved login and a generated date.
  function searchPath(endpoint, terms) {
    return "/search/" + endpoint + "?q=" + terms.join("+") + "&per_page=100"
  }

  function authorTerm() {
    return "author:" + encodeURIComponent(login)
  }

  // Search queries cannot use @me, so nothing can be fetched before `gh api
  // user` has answered. That fetch restarts the burst once it lands.
  function haveLogin() {
    if (login !== "") return true
    if (!loginProc.running) loginProc.running = true
    return false
  }

  function startGithubFetches() {
    if (countMergedPrs) startPrFetch()
    else prError = false
    if (countClosedIssues) startIssueFetch()
    else issueError = false
    if (countCommits) startCommitFetch()
    else commitError = false
  }

  function startPrFetch() {
    if (prProc.running || !haveLogin()) return
    prResponded = false
    prProc.command = ["timeout", "30", "gh", "api", searchPath("issues",
      [authorTerm(), "is:pr", "is:merged", "merged:%3E%3D" + searchSinceDate()])]
    prProc.running = true
  }

  function startIssueFetch() {
    if (issueProc.running || !haveLogin()) return
    issueResponded = false
    issueProc.command = ["timeout", "30", "gh", "api", searchPath("issues",
      [authorTerm(), "is:issue", "is:closed", "closed:%3E%3D" + searchSinceDate()])]
    issueProc.running = true
  }

  // Commit search indexes default branches only; any-branch and non-GitHub
  // work reaches the panel through the local scan.
  function startCommitFetch() {
    if (commitProc.running || !haveLogin()) return
    commitResponded = false
    commitProc.command = ["timeout", "30", "gh", "api", searchPath("commits",
      [authorTerm(), "author-date:%3E%3D" + searchSinceDate()])]
    commitProc.running = true
  }

  // A search response is usable only when it carries an items array. An empty
  // body, an error object or anything unparseable leaves the source failed,
  // with its last good list still on screen.
  function searchOk(raw) {
    try {
      var parsed = JSON.parse(String(raw === undefined || raw === null ? "" : raw))
      return !!parsed && Array.isArray(parsed.items)
    } catch (e) {
      return false
    }
  }

  function startLocalFetch() {
    if (localProc.running) return
    if (localRepoDirs.length === 0) {
      localItems = []
      localError = false
      return
    }
    var args = ["timeout", "60", "bash", localScript, String(Math.floor(dayStartMs / 1000))]
    for (var i = 0; i < localRepoDirs.length; i++) args.push(localRepoDirs[i])
    localResponded = false
    localProc.command = args
    localProc.running = true
  }

  Process {
    id: loginProc
    command: ["timeout", "15", "gh", "api", "user", "--jq", ".login"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = String(text || "").replace(/^\s+|\s+$/g, "")
        if (name === "" || name.indexOf(" ") !== -1) return
        root.login = name
        if (root.githubEnabled) root.startGithubFetches()
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0 || root.login !== "") return
      root.prError = true
      root.issueError = true
      root.commitError = true
    }
  }

  Process {
    id: prProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.searchOk(text)) return
        root.prItems = Model.normalizeSearchPrs(text)
        root.prResponded = true
        root.prError = false
        root.markFresh()
      }
    }
    onExited: if (!root.prResponded) root.prError = true
  }

  Process {
    id: issueProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.searchOk(text)) return
        root.issueItems = Model.normalizeSearchIssues(text)
        root.issueResponded = true
        root.issueError = false
        root.markFresh()
      }
    }
    onExited: if (!root.issueResponded) root.issueError = true
  }

  Process {
    id: commitProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.searchOk(text)) return
        root.commitItems = Model.normalizeSearchCommits(text)
        root.commitResponded = true
        root.commitError = false
        root.markFresh()
      }
    }
    onExited: if (!root.commitResponded) root.commitError = true
  }

  Process {
    id: localProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.localItems = Model.normalizeLocalCommits(text)
        root.localResponded = true
        root.localError = false
        root.markFresh()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.localResponded) root.localError = true
    }
  }

  Timer {
    id: pollTimer
    interval: root.pollMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Day rollover --------------------------------------------------------

  function scheduleRollover() {
    var next = Model.dayStartMs(Date.now() + 86400000, dayBoundary)
    var delay = next - Date.now()
    if (!isFinite(delay) || delay <= 0) delay = 86400000
    rolloverTimer.interval = Math.max(1000, Math.round(delay))
    rolloverTimer.restart()
  }

  // The finished day is written to the cache before the window moves, which is
  // what puts yesterday's total in the week strip. The item lists need no
  // clearing: mergeItems filters against the new dayStart, so they self-empty.
  function rollDay() {
    advanceDay()
    scheduleRollover()
    refresh()
  }

  Timer {
    id: rolloverTimer
    repeat: false
    onTriggered: root.rollDay()
  }

  // ---- Week strip cache ----------------------------------------------------

  // Never write before the file has resolved: an early write would replace the
  // stored days with today alone.
  property bool stateLoaded: false

  function persistCounts() {
    if (!stateLoaded) return
    var next = stateObject
    if (!next) return
    // Fold the merged result back into the base so the next merge, and the
    // merge that runs after the day rolls over, still carry this day.
    stateText = JSON.stringify(next)
    stateFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/shiplog.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.stateText = text()
      root.stateLoaded = true
    }
    // First run: the file does not exist yet. Without this branch the cache
    // would never be written and the week strip would stay empty forever.
    onLoadFailed: {
      root.stateText = ""
      root.stateLoaded = true
    }
  }

  Timer {
    id: stateSaveTimer
    interval: 250
    repeat: false
    onTriggered: root.persistCounts()
  }

  Component.onCompleted: scheduleRollover()

  // ---- Row actions ---------------------------------------------------------

  function typeGlyph(type) {
    if (type === "commit") return "\u21e1"
    if (type === "pr") return "\u2197"
    if (type === "issue") return "\u2713"
    return "\u2022"
  }

  function repoLabel(repo) {
    var name = String(repo || "")
    if (name.charAt(0) !== "/") return name
    var home = Quickshell.env("HOME")
    if (home !== "" && name.indexOf(home) === 0) return "~" + name.substr(home.length)
    return name
  }

  function timeLabel(timestamp) {
    var value = Number(timestamp)
    if (!isFinite(value) || value <= 0) return ""
    return Qt.formatDateTime(new Date(value), "HH:mm")
  }

  // The by-type split, in one string. The bar chip shows this as its tooltip,
  // so the marks and the order cannot drift between chip and panel.
  readonly property string splitLabel: typeGlyph("commit") + " " + (todayCounts.commits || 0)
    + "   " + typeGlyph("pr") + " " + (todayCounts.prs || 0)
    + "   " + typeGlyph("issue") + " " + (todayCounts.issues || 0)

  // Only web URLs may leave the shell: search responses are third-party data,
  // and Qt.openUrlExternally would happily hand file: or other schemes to the
  // system opener.
  function openItem(item) {
    if (!item || !item.url) return
    var url = String(item.url)
    if (!/^https?:\/\//i.test(url)) return
    Qt.openUrlExternally(url)
    root.close()
  }

  function openSelected() {
    if (selectedIndex < 0 || selectedIndex >= flatItems.length) return
    openItem(flatItems[selectedIndex])
  }

  function moveSelection(delta) {
    var count = flatItems.length
    if (count === 0) {
      selectedIndex = -1
      return
    }
    var next = selectedIndex < 0 ? (delta > 0 ? 0 : count - 1) : selectedIndex + delta
    selectedIndex = Math.max(0, Math.min(count - 1, next))
    scrollToSelection()
  }

  function noteRowGeometry(index, top, height) {
    rowGeometry[index] = { top: top, height: height }
    if (index === selectedIndex) Qt.callLater(scrollToSelection)
  }

  function scrollToSelection() {
    var geometry = rowGeometry[selectedIndex]
    if (!geometry || listScroll.height <= 0) return
    var limit = Math.max(0, listScroll.contentHeight - listScroll.height)
    if (geometry.top < listScroll.contentY)
      listScroll.contentY = Math.max(0, Math.min(geometry.top, limit))
    else if (geometry.top + geometry.height > listScroll.contentY + listScroll.height)
      listScroll.contentY = Math.max(0, Math.min(geometry.top + geometry.height - listScroll.height, limit))
  }

  property bool recentlyCopied: false

  function copyDay() {
    var markdown = Model.markdownRecap(items, dateLabel)
    if (!markdown) return
    Quickshell.execDetached(["wl-copy", "--", String(markdown)])
    recentlyCopied = true
    copiedTimer.restart()
  }

  Timer {
    id: copiedTimer
    interval: 1400
    repeat: false
    onTriggered: root.recentlyCopied = false
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.ipcRefresh() }

    // `copy` is the verb the panel's own footer button means; `copyDay` is the
    // name the bar widget forwards under, so either spelling reaches the same
    // clipboard write.
    function copy(): void { root.copyDay() }
    function copyDay(): void { root.copyDay() }
  }

  // ---- UI ------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(shiplogColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onActivateRequested: root.openSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(character) {
        if (character === "r") root.refresh()
        else if (character === "c") root.copyDay()
      }

      Column {
        id: shiplogColumn
        width: keyCatcher.width
        spacing: Style.spacing.panelGap

        // ---- Hero: the count, what it counts, and which day it is.
        PanelHero {
          title: "Shipped today"
          meta: root.dateLabel
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconOpacity: root.totalCount > 0 ? 1 : 0.45

          iconComponent: Component {
            // Held to a two-digit box so "Shipped today" does not step
            // sideways the first time the day reaches 10 — the same
            // fixed-width hold clock/Panel.qml:714 gives its month label so
            // the chevrons either side of it stay put.
            Item {
              implicitWidth: Math.max(heroCount.implicitWidth,
                Math.round(heroCount.font.pixelSize * 1.2))
              implicitHeight: heroCount.implicitHeight

              Text {
                id: heroCount
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.totalCount > 0 ? String(root.totalCount) : "\uf21a"
                color: root.foreground
                font.family: root.fontFamily
                // Hero read-out: a fixed step above the largest scale token
                // rather than a frozen pixel size. The count is the panel's
                // one focal point, and a theme that raises [font] base-size
                // has to grow it too or the title beside it catches up.
                // Same derive-from-a-token move as LockView.qml:24.
                font.pixelSize: Math.round(Style.font.displayLarge * 1.5)
                font.bold: root.totalCount > 0
              }
            }
          }
        }

        // ---- Split by type. Same three marks the bar chip's tooltip uses.
        Row {
          visible: root.totalCount > 0
          spacing: Style.spacing.huge

          Repeater {
            model: [
              { glyph: root.typeGlyph("commit"), count: root.todayCounts.commits, label: "pushed" },
              { glyph: root.typeGlyph("pr"), count: root.todayCounts.prs, label: "merged" },
              { glyph: root.typeGlyph("issue"), count: root.todayCounts.issues, label: "closed" }
            ]

            Row {
              required property var modelData
              spacing: Style.spacing.md

              // Three sizes on one line, so they hang off a shared baseline
              // rather than three centered boxes — centering leaves the mark
              // sitting low against the digits (clock/Panel.qml:296).
              Text {
                anchors.baseline: splitCount.baseline
                text: modelData.glyph
                color: modelData.count > 0 ? root.foreground : root.dimmer
                font.family: root.fontFamily
                // The same size these three marks are given in the list
                // below, so a mark means one thing at one size wherever it
                // appears. At body it also outsized nothing and undersized
                // nothing — a 15-against-16 wobble instead of a step.
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                id: splitCount
                text: String(modelData.count || 0)
                color: modelData.count > 0 ? root.foreground : root.dimmer
                font.family: root.fontFamily
                // One step over the row titles below. Bold alone does not
                // separate a summary from a list in a monospace family.
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                anchors.baseline: splitCount.baseline
                // Uppercased where it is drawn, not in the model: tracking
                // is a capitals device, and this is the panel's third small
                // label after the hero's date (PanelHero.qml:92) and the
                // week's day letters, both of which already set caps.
                text: String(modelData.label).toUpperCase()
                color: root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }
          }
        }

        PanelSeparator {
          visible: root.totalCount > 0
          foreground: root.foreground
        }

        // ---- Zero state. Never guilt-toned: the day is simply young.
        //
        // No mark of its own: on an empty day the hero is already showing
        // the ship in place of a count, and the same glyph twice within a
        // hero's height reads as a rendering mistake rather than a motif.
        Column {
          visible: root.flatItems.length === 0
          width: parent.width
          // The empty body is the whole panel here, so it gets more than a
          // sibling's worth of air above and below.
          topPadding: Style.spacing.huge
          bottomPadding: Style.spacing.huge

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Nothing shipped yet \u2014 the day is young."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- Body: repositories, newest first, newest item first inside each.
        Flickable {
          id: listScroll
          visible: root.flatItems.length > 0
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(300))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: listColumn
            width: listScroll.width
            spacing: Style.spacing.xl

            Repeater {
              model: root.groups

              Column {
                id: group
                required property var modelData
                required property int index
                readonly property int flatOffset: root.groupOffsets[index] || 0
                width: listColumn.width
                spacing: Style.spacing.xxs

                PanelSectionHeader {
                  text: root.repoLabel(group.modelData.repo)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  width: parent.width
                  elide: Text.ElideMiddle
                  textFormat: Text.PlainText
                }

                Repeater {
                  model: group.modelData.items

                  CursorSurface {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property int flatIndex: group.flatOffset + index
                    readonly property bool linkable: !!modelData.url

                    width: group.width
                    height: Style.spacing.popupRowHeight
                    hasCursor: root.selectedIndex === flatIndex
                    foreground: root.foreground
                    accent: Color.accent

                    // Absolute top inside the list column: the row's own y is
                    // relative to its group, so the group's y has to move it too.
                    readonly property real listTop: group.y + y
                    onListTopChanged: root.noteRowGeometry(flatIndex, listTop, height)
                    onHeightChanged: root.noteRowGeometry(flatIndex, listTop, height)
                    Component.onCompleted: root.noteRowGeometry(flatIndex, listTop, height)

                    Text {
                      id: rowGlyph
                      anchors.left: parent.left
                      anchors.leftMargin: Style.spacing.rowPaddingX
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.typeGlyph(row.modelData.type)
                      color: row.linkable ? root.dim : root.dimmer
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      id: rowTime
                      anchors.right: parent.right
                      anchors.rightMargin: Style.spacing.rowPaddingX
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.timeLabel(row.modelData.ts)
                      color: root.dimmer
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      anchors.left: rowGlyph.right
                      anchors.leftMargin: Style.spacing.lg
                      anchors.right: rowTime.left
                      anchors.rightMargin: Style.spacing.xl
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(row.modelData.title || "")
                      color: row.linkable ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: row.linkable ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onEntered: root.selectedIndex = row.flatIndex
                      onClicked: root.openItem(row.modelData)
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Stale-data notice. Quiet, and never in place of the data.
        Row {
          visible: root.hasError
          width: parent.width
          spacing: Style.spacing.md

          // Urgent off the bar rather than the palette, the way the rest of
          // the kit reads it (WidgetButton.qml:12), so a bar overriding its
          // own urgent color is honored in the panel too.
          Text {
            id: errorMark
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf071"
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            opacity: 0.85
          }
          Text {
            // Bounded and elided rather than left to run off the card. Both
            // sources failing spells a line half again wider than the panel,
            // and the chip's tooltip carries the sentence in full anyway.
            width: parent.width - errorMark.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: root.errorSummary
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.fontFamily
            // Matched to the mark beside it, and never the smallest type in
            // the panel: this is the one line that explains why the numbers
            // above it are behind. Still a step under the rows it qualifies.
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            opacity: 0.85
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ---- Footer: the week's receipts, when it last refreshed, and the
        //      one-click day recap.
        Item {
          width: parent.width
          height: Math.max(weekRow.implicitHeight, footerActions.implicitHeight)

          Row {
            id: weekRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg

            Repeater {
              model: root.weekCells

              Column {
                required property var modelData
                spacing: Style.spacing.xxs
                // Sized by the digits it has to hold rather than by a flat
                // 20: a three-figure day painted the full width of its cell
                // with nothing left either side, closing the strip up
                // exactly on the days worth reading.
                width: Math.round(Style.font.bodySmall * 2)

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: String(modelData.label || "").substr(0, 1).toUpperCase()
                  color: modelData.isToday ? Color.accent : root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: String(modelData.count || 0)
                  color: modelData.isToday
                    ? Color.accent
                    : (modelData.count > 0 ? root.foreground : root.dimmer)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: modelData.isToday
                }
              }
            }
          }

          Row {
            id: footerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg

            Text {
              visible: root.updatedLabel !== ""
              anchors.verticalCenter: parent.verticalCenter
              text: "Updated " + root.updatedLabel
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              enabled: root.flatItems.length > 0
              iconText: root.recentlyCopied ? "\uf00c" : "\uf0c5"
              tooltipText: root.recentlyCopied ? "Copied" : "Copy day as Markdown"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.copyDay()
            }
          }
        }
      }
    }
  }
}
