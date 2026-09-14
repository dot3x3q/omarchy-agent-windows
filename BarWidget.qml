// Bar pill with status badges and a panel listing every pane on every
// machine. Clicking a pane opens or focuses its window via bin/agent-window.
//
// Panel scaffolding (Panel, KeyboardPanel, PanelHero, popout handling)
// follows the shape of BarWidget.qml in carlotran4/omarchy-herdr (MIT) and
// Omarchy's own first-party widgets - see THIRD_PARTY.md.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Backend.js" as Backend

Panel {
  id: root
  moduleName: "rubys.agent-windows"
  manageIpc: false

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property var machineConfigs: Backend.machinesFrom(setting("machines", [{ label: "local" }]))
  readonly property bool showShells: setting("showShells", true)
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.52)
  readonly property bool iconVisible: vertical || setting("showIcon", true)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var statusColors: ({
    blocked: "#f7768e",
    done: "#9ece6a",
    working: "#7aa2f7",
    unknown: "#e0af68",
    idle: "#737aa2",
    shell: "#565f89"
  })

  // Aggregate across machines. Rebuilt on any machine's changed() signal.
  property var panes: []
  property var machineStates: []
  readonly property var counts: Backend.counts(panes)
  readonly property var sortedPanes: Backend.sortedPanes(panes)
  readonly property var attentionPane: Backend.attentionPane(panes)
  readonly property bool anyOnline: machineStates.some(function(m) { return m.online })

  visible: iconVisible || panes.length > 0 || !anyOnline
  implicitWidth: vertical ? barSize : Math.max(barSize, barContent.implicitWidth + Style.space(12))
  implicitHeight: barSize

  function rebuild() {
    var all = []
    var states = []
    for (var i = 0; i < machines.count; i++) {
      var m = machines.objectAt(i)
      if (!m) continue
      states.push({ label: m.label, online: m.online, remote: m.remote, error: m.lastError, socketPath: m.socketPath })
      var rows = m.panes || []
      for (var j = 0; j < rows.length; j++) {
        if (!root.showShells && rows[j].status === "shell") continue
        all.push(rows[j])
      }
    }
    panes = all
    machineStates = states
    syncWindowTags()
  }

  // Paint pane windows by status through Hyprland tags (bin/agent-tags).
  // Only runs when the class->status picture actually changed, so a burst of
  // events costs one process at most, and none when nothing moved.
  property string lastTagKey: "unset"
  function syncWindowTags() {
    var args = []
    for (var i = 0; i < panes.length; i++) {
      var p = panes[i]
      if (p.status !== "blocked" && p.status !== "done") continue
      if (!p.terminal_id) continue
      args.push("agent-windows." + p.machine + "." + p.terminal_id + "=" + p.status)
    }
    args.sort()
    var key = args.join("\n")
    if (key === lastTagKey) return
    lastTagKey = key
    Quickshell.execDetached([root.pluginDir + "/bin/agent-tags", "sync"].concat(args))
  }

  Component.onCompleted: Quickshell.execDetached([root.pluginDir + "/bin/agent-tags", "rules"])

  function machineFor(label) {
    for (var i = 0; i < machines.count; i++) {
      var m = machines.objectAt(i)
      if (m && m.label === label) return m
    }
    return null
  }

  function refreshAll() {
    for (var i = 0; i < machines.count; i++) {
      var m = machines.objectAt(i)
      if (m) m.refresh()
    }
  }

  // Open (or focus) the pane's window. The in-server focus goes first so a
  // finished agent is marked seen and any other client lands there too.
  function openPane(pane) {
    if (!pane) return
    var m = machineFor(pane.machine)
    if (m && pane.agent !== "") m.focusPane(pane.pane_id)
    Quickshell.execDetached([
      root.pluginDir + "/bin/agent-window", "open",
      pane.machine, pane.ssh !== "" ? pane.ssh : "-", pane.session,
      pane.terminal_id, pane.machine + " · " + Backend.paneLabel(pane, 60)
    ])
    lastTagKey = "unset"
    tagRetouch.restart()
    close()
  }

  function openAttention() { openPane(attentionPane) }

  function createPaneOn(label) {
    var m = machineFor(label)
    if (m) m.createPane()
  }

  function open() {
    controller.show()
    if (bar && typeof bar.requestPopout === "function") bar.requestPopout(root)
  }

  function close() {
    controller.hide()
    if (bar && typeof bar.releasePopout === "function") bar.releasePopout(root)
  }

  function toggle() {
    if (opened) close()
    else open()
  }

  // Focusing a pane window directly (not through the panel) should count as
  // seeing it, the way focusing the pane in Herdr's own UI does: tell the
  // server, which turns a finished agent back to idle and drops the badge.
  readonly property string activeAppId: ToplevelManager.activeToplevel ? String(ToplevelManager.activeToplevel.appId || "") : ""
  onActiveAppIdChanged: {
    if (activeAppId.indexOf("agent-windows.") !== 0) return
    var parts = activeAppId.split(".")
    if (parts.length < 3) return
    var machineLabel = parts[1]
    var terminalId = parts.slice(2).join(".")
    for (var i = 0; i < panes.length; i++) {
      var p = panes[i]
      if (p.machine === machineLabel && p.terminal_id === terminalId) {
        var m = machineFor(p.machine)
        if (m && p.agent !== "" && (p.status === "done" || p.status === "blocked")) m.focusPane(p.pane_id)
        return
      }
    }
  }

  // A window opened for a pane that is already blocked or done needs its
  // tag once it exists; foot takes a moment to map.
  Timer { id: tagRetouch; interval: 1500; repeat: false; onTriggered: root.syncWindowTags() }

  Instantiator {
    id: machines
    model: root.machineConfigs
    delegate: Machine {
      machine: modelData
      pluginDir: root.pluginDir
      onChanged: root.rebuild()
      onPaneCreated: function(pane) { root.openPane(pane) }
    }
    onObjectAdded: function(index, object) { root.rebuild() }
    onObjectRemoved: function(index, object) { root.rebuild() }
  }

  Rectangle {
    id: button
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.opened ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

    Behavior on color { ColorAnimation { duration: 120 } }

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(7)

      Text {
        visible: root.iconVisible
        text: "󱂬"
        color: root.foreground
        opacity: root.anyOnline ? 1 : 0.45
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        anchors.verticalCenter: parent.verticalCenter
      }

      Repeater {
        model: root.vertical ? [] : Backend.BADGE_ORDER

        Row {
          required property string modelData
          readonly property int count: Number(root.counts[modelData] || 0)
          visible: count > 0
          width: visible ? implicitWidth : 0
          spacing: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            width: Style.space(5)
            height: width
            radius: width / 2
            color: root.statusColors[modelData]
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: parent.count
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor

      onEntered: if (root.bar) root.bar.showTooltip(button, Backend.tooltip(root.panes, root.machineStates))
      onExited: if (root.bar) root.bar.hideTooltip(button)
      onClicked: function(mouse) {
        if (root.bar) root.bar.hideTooltip(button)
        if (mouse.button === Qt.RightButton) root.refreshAll()
        else if (mouse.button === Qt.MiddleButton) root.openAttention()
        else root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: fittedContentWidth(Style.space(380))
    contentHeight: fittedContentHeight(panelContent.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.openAttention()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelContent.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: panelContent
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Agent Windows"
            meta: root.panes.length + " pane" + (root.panes.length === 1 ? "" : "s")
              + " on " + root.machineStates.filter(function(m) { return m.online }).length
              + " of " + root.machineStates.length + " machine" + (root.machineStates.length === 1 ? "" : "s")
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: "󱂬"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
              }
            }
          }

          // Machine chips: online/offline at a glance.
          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.machineStates

              Rectangle {
                id: chip
                required property var modelData
                readonly property bool canCreate: modelData.online
                width: chipLabel.implicitWidth + Style.space(16) + (canCreate ? plusArea.width : 0)
                height: Style.space(26)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                border.width: 1
                border.color: modelData.online ? root.statusColors.done : root.statusColors.blocked
                opacity: modelData.online ? 1 : 0.7

                Text {
                  id: chipLabel
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: (chip.modelData.remote ? "󰒍 " : "󰇅 ") + chip.modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: chipLabel.implicitWidth + Style.space(16)
                  hoverEnabled: true
                  onEntered: if (root.bar) root.bar.showTooltip(chip, chip.modelData.online
                    ? chip.modelData.socketPath
                    : (chip.modelData.error || "offline") + "\n" + chip.modelData.socketPath)
                  onExited: if (root.bar) root.bar.hideTooltip(chip)
                }

                // New shell pane on this machine, opened as a window at once.
                Rectangle {
                  id: plusArea
                  visible: chip.canCreate
                  width: visible ? Style.space(22) : 0
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.margins: 1
                  radius: height / 2
                  color: plusMouse.containsMouse
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  MouseArea {
                    id: plusMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: if (root.bar) root.bar.showTooltip(plusArea, "New shell on " + chip.modelData.label)
                    onExited: if (root.bar) root.bar.hideTooltip(plusArea)
                    onClicked: {
                      if (root.bar) root.bar.hideTooltip(plusArea)
                      root.createPaneOn(chip.modelData.label)
                    }
                  }
                }
              }
            }
          }

          PanelSeparator {
            visible: root.panes.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.panes.length > 0
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.sortedPanes

              Rectangle {
                id: paneCard
                required property var modelData
                width: parent.width
                height: Style.space(66)
                radius: Style.cornerRadius
                color: paneMouse.containsMouse
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

                Behavior on color { ColorAnimation { duration: 100 } }

                Rectangle {
                  width: Style.space(4)
                  radius: width / 2
                  color: root.statusColors[paneCard.modelData.status]
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.topMargin: Style.space(10)
                  anchors.bottomMargin: Style.space(10)
                }

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.right: statusText.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Text {
                    width: parent.width
                    text: Backend.paneLabel(paneCard.modelData, 44)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: paneCard.modelData.machine
                      + (paneCard.modelData.agent !== "" ? " · " + paneCard.modelData.agent : "")
                      + " · " + Backend.shortenPath(paneCard.modelData.cwd, 40)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }

                Text {
                  id: statusText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: Backend.STATUS_LABELS[paneCard.modelData.status]
                  color: root.statusColors[paneCard.modelData.status]
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: paneMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openPane(paneCard.modelData)
                }
              }
            }
          }

          Text {
            visible: root.panes.length === 0
            width: parent.width
            topPadding: Style.space(22)
            bottomPadding: Style.space(22)
            text: root.anyOnline
              ? "No panes yet. Anything Herdr runs shows up here."
              : "No Herdr server reachable. Machines reconnect on their own."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.panes.length > 0
            width: parent.width
            text: "Click a pane to open its window · Enter opens the most urgent"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
