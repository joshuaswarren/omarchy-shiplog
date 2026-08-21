import QtQuick
import qs.Commons
import qs.Ui

// Bar chip for Shiplog: a ship glyph plus today's shipped count. The chip is
// a thin wrapper: Panel.qml owns the data engine and every piece of mutable
// state, and this widget reads its public surface.
//
// Left click toggles the day log, right and middle click refresh now.
BarWidget {
  id: root
  moduleName: "io.github.joshuaswarren.shiplog"

  // nf-fa-ship. Font Awesome's block is present in every Nerd Font patch,
  // which is what the bar font resolves to; swap this one string to change
  // the mark.
  readonly property string glyph: "\uf21a"

  readonly property int totalCount: panelLoader.item ? panelLoader.item.totalCount : 0
  readonly property bool hasError: panelLoader.item ? panelLoader.item.hasError === true : false
  readonly property string splitLabel: panelLoader.item && "splitLabel" in panelLoader.item
    ? String(panelLoader.item.splitLabel) : ""
  readonly property string errorSummary: panelLoader.item && "errorSummary" in panelLoader.item
    ? String(panelLoader.item.errorSummary) : ""

  readonly property string chipCount: totalCount > 0 ? String(totalCount) : ""
  readonly property bool dimGlyph: totalCount === 0 && !hasError

  // One bar slot for the mark, a second for the count once something has
  // shipped. The vertical height is derived from this, never read back off the
  // positioner: WidgetButton.qml:69 passes our fixedHeight straight through to
  // its own implicitHeight, so a chip that measured its own centered child
  // would size the item that child anchors into.
  readonly property int chipSlots: chipCount === "" ? 1 : 2

  readonly property bool hideWhenZero: {
    var value = setting("hideWhenZero", false)
    return value === true || String(value).toLowerCase() === "true"
  }
  readonly property bool collapsed: hideWhenZero && totalCount === 0 && !hasError

  readonly property color baseForeground: bar ? bar.barForeground : Color.foreground
  readonly property string chipFontFamily: bar ? bar.fontFamily : Style.font.family

  // One accent wash when the count grows. `pulse` drives a tint over the bar
  // foreground so the chip carries the accent for a beat and settles back.
  // The wash is a hue shift rather than a brightening: a palette is free to
  // sit its accent either side of its foreground, and both read as a change.
  property real pulse: 0
  property int seenTotal: -1
  readonly property color chipForeground: pulse > 0
    ? Qt.tint(baseForeground, Util.alpha(Color.accent, pulse))
    : baseForeground

  readonly property string chipTooltip: errorSummary === ""
    ? splitLabel
    : (splitLabel === "" ? errorSummary : splitLabel + "\n" + errorSummary)

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // The shell hands a called method one string argument (shell.qml:573), so
  // the parameter is declared and ignored rather than left to arity.
  function copyDay(arg) {
    if (panelLoader.item && panelLoader.item.copyDay) panelLoader.item.copyDay()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root). Open maps to the
  // panel's hotkey path so summoning suppresses the center hover reveal.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: !collapsed
  implicitWidth: collapsed ? 0 : button.implicitWidth
  implicitHeight: collapsed ? 0 : button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // The first count of a session is what was already shipped before the shell
  // started, so it arrives as a jump from nothing and must not pulse.
  onTotalCountChanged: {
    if (seenTotal >= 0 && totalCount > seenTotal) pulseAnimation.restart()
    seenTotal = totalCount
  }

  SequentialAnimation {
    id: pulseAnimation

    NumberAnimation {
      target: root
      property: "pulse"
      to: 1
      duration: 180
      easing.type: Easing.OutCubic
    }
    NumberAnimation {
      target: root
      property: "pulse"
      to: 0
      duration: 420
      easing.type: Easing.InCubic
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.chipTooltip
    // The button's own side padding rather than a number of our own: every
    // other bar widget is label + scaledHorizontalMargin * 2 wide
    // (WidgetButton.qml:68), so borrowing it puts this chip on the same
    // rhythm as the chips either side of it.
    fixedWidth: root.vertical
      ? -1
      : Math.max(Style.bar.statusSlot, chip.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? root.chipSlots * Style.bar.iconSlot : -1

    // An empty day is the bar's own dimmed state, so it rides the bar's own
    // dimming (WidgetButton.qml:67) instead of a second opacity of ours.
    dimmed: root.dimGlyph

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton || pressedButton === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    // One positioner for both orientations, the way the remnic chip and the
    // clock's line stack do it: the mark beside the count on a horizontal bar,
    // the mark over it on a vertical one. The count cell drops out of the
    // layout entirely until the first item of the day lands.
    Grid {
      id: chip
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 2
      columnSpacing: Style.spacing.sm
      rowSpacing: 0
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      Item {
        width: root.vertical ? Style.bar.iconSlot : Style.bar.iconCanvas
        height: width

        OpticalGlyph {
          anchors.fill: parent
          text: root.glyph
          fontFamily: root.chipFontFamily
          fontSize: Style.bar.iconFont
          color: root.chipForeground
        }

        // Urgent is read off the bar rather than the palette, the way every
        // other bar widget reads it (WidgetButton.qml:12), so a bar that
        // overrides its own active color is honored here too.
        Rectangle {
          visible: opacity > 0
          opacity: root.hasError ? 1 : 0
          width: Math.max(Style.spacing.sm, Math.round(Style.bar.iconFont * 0.32))
          height: width
          radius: width / 2
          anchors.right: parent.right
          anchors.top: parent.top
          color: root.bar ? root.bar.urgent : Color.urgent

          // Fades rather than pops: a source going stale is not an event the
          // user caused, so it arrives at the same 140ms the bar fades its
          // own widgets in and out at (WidgetButton.qml:72).
          Behavior on opacity {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }
        }
      }

      Text {
        id: countText
        visible: root.chipCount !== ""
        width: root.vertical ? Style.bar.iconSlot : countText.implicitWidth
        height: root.vertical ? Style.bar.iconSlot : countText.implicitHeight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.chipCount
        color: root.chipForeground
        font.family: root.chipFontFamily
        font.pixelSize: root.vertical && root.chipCount.length > 2
          ? Math.round(Style.bar.iconFont * 0.8)
          : Style.bar.iconFont
        renderType: Text.NativeRendering
      }
    }
  }
}
