// One Herdr server: a request socket, a held-open event subscription, and,
// for SSH machines, the forward that puts the remote socket on this
// filesystem. Emits normalized pane records; nothing else in the plugin
// speaks Herdr.
//
// The socket lifecycle (one-shot request sockets, subscription rebuild on
// pane-set change, bounded reconnect) is adapted from HerdrModel.qml in
// carlotran4/omarchy-herdr (MIT) - see THIRD_PARTY.md.
import QtQuick
import Quickshell
import Quickshell.Io
import "Backend.js" as Backend

QtObject {
  id: root

  // From the machines setting, already normalized by Backend.machinesFrom.
  property var machine: ({ label: "local", ssh: "", session: "default" })
  property string pluginDir: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + Quickshell.env("UID"))
  readonly property string label: machine.label
  readonly property bool remote: machine.ssh !== ""
  readonly property string socketPath: Backend.localSocketPath(machine, home, runtimeDir)

  property var panes: []
  property bool online: false
  property string lastError: ""
  property bool refreshPending: false
  property int requestSequence: 0
  property int reconnectDelayMs: 1000
  property var requestQueue: []
  property var activeRequest: null
  property bool commandBusy: false
  property string subscribedPaneKey: ""

  signal changed()
  signal focusSucceeded(string paneId)
  signal paneCreated(var pane)

  function requestId(kind) {
    requestSequence++
    return "agent-windows:" + label + ":" + Date.now() + ":" + requestSequence + ":" + kind
  }

  function enqueue(method, params, kind) {
    var next = requestQueue.slice()
    next.push({ method: method, params: params || {}, kind: kind, id: requestId(kind) })
    requestQueue = next
    startNextRequest()
  }

  function startNextRequest() {
    if (commandBusy || requestQueue.length === 0 || socketPath === "") return
    var next = requestQueue.slice()
    activeRequest = next.shift()
    requestQueue = next
    commandBusy = true
    commandSocket.connected = true
  }

  function sendActiveRequest() {
    if (!commandSocket.connected || !activeRequest) return
    commandTimeout.restart()
    commandSocket.write(JSON.stringify({
      id: activeRequest.id,
      method: activeRequest.method,
      params: activeRequest.params
    }) + "\n")
    commandSocket.flush()
  }

  function finishRequest() {
    commandTimeout.stop()
    activeRequest = null
    commandBusy = false
    commandSocket.connected = false
    commandKick.restart()
  }

  function refresh() {
    if (refreshPending) return
    refreshPending = true
    enqueue("pane.list", {}, "list")
  }

  // Focusing inside the server is what clears a "done" agent back to idle,
  // and it lands any other attached client on the same pane.
  function focusPane(paneId) {
    if (paneId) enqueue("pane.focus", { pane_id: paneId }, "focus:" + paneId)
  }

  // A new shell tab in the server's current workspace; the response carries
  // the root pane, so the caller can open its window without waiting for
  // the pane.created event to round-trip through a list refresh.
  function createPane() {
    if (online) enqueue("tab.create", { focus: false }, "create")
  }

  function reconnect() {
    reconnectTimer.stop()
    subscriptionRetry.stop()
    commandSocket.connected = false
    subscriptionSocket.connected = false
    activeRequest = null
    commandBusy = false
    requestQueue = []
    refreshPending = false
    panes = []
    online = false
    reconnectDelayMs = 1000
    changed()
    reconnectKick.restart()
  }

  function scheduleReconnect() {
    commandTimeout.stop()
    var wasOnline = online
    online = false
    refreshPending = false
    activeRequest = null
    commandBusy = false
    requestQueue = []
    commandSocket.connected = false
    if (wasOnline) { panes = []; changed() }
    if (!reconnectTimer.running) reconnectTimer.start()
  }

  function handleCommandLine(line) {
    var payload
    try {
      payload = JSON.parse(String(line))
    } catch (error) {
      lastError = "invalid JSON from Herdr"
      scheduleReconnect()
      return
    }

    if (!activeRequest || String(payload.id || "") !== activeRequest.id) return
    var kind = activeRequest.kind
    if (payload.error) {
      lastError = String(payload.error.message || "request failed")
      if (kind === "list") scheduleReconnect()
      else finishRequest()
      return
    }

    if (kind === "list") {
      refreshPending = false
      var result = payload.result || {}
      var rows = Array.isArray(result.panes) ? result.panes : []
      var next = []
      for (var i = 0; i < rows.length; i++) next.push(Backend.normalizePane(machine, rows[i]))
      panes = next
      online = true
      lastError = ""
      reconnectDelayMs = 1000
      reconnectTimer.stop()
      changed()
      rebuildSubscription()
    } else if (kind.indexOf("focus:") === 0) {
      focusSucceeded(kind.slice(6))
    } else if (kind === "create") {
      var created = (payload.result || {}).root_pane
      if (created) paneCreated(Backend.normalizePane(machine, created))
      refresh()
    }
    finishRequest()
  }

  function rebuildSubscription() {
    var nextKey = Backend.paneKey(panes)
    if (subscriptionSocket.connected && nextKey === subscribedPaneKey) return
    subscribedPaneKey = nextKey
    subscriptionSocket.connected = false
    subscriptionKick.restart()
  }

  function sendSubscription() {
    if (!subscriptionSocket.connected) return
    subscriptionSocket.write(JSON.stringify({
      id: requestId("subscribe"),
      method: "events.subscribe",
      params: { subscriptions: Backend.subscriptions(panes) }
    }) + "\n")
    subscriptionSocket.flush()
  }

  function handleSubscriptionLine(line) {
    var payload
    try {
      payload = JSON.parse(String(line))
    } catch (error) {
      return
    }
    if (payload.error) {
      lastError = String(payload.error.message || "subscription failed")
      subscriptionSocket.connected = false
      subscriptionRetry.restart()
    } else if (!payload.id) {
      // Events are invalidation signals; the list is the source of truth.
      refresh()
    }
  }

  onSocketPathChanged: reconnect()

  property Socket commandSocket: Socket {
    path: root.socketPath
    parser: SplitParser { onRead: function(line) { root.handleCommandLine(line) } }
    onConnectedChanged: if (connected) root.sendActiveRequest()
    onError: function(errorCode) {
      // Herdr closes request sockets after one response; that PeerClosed
      // arrives while the timeout is running and is normal. A failure to
      // connect never starts the timer and should back off.
      if (root.commandBusy && !root.commandTimeout.running) root.scheduleReconnect()
    }
  }

  property Socket subscriptionSocket: Socket {
    path: root.socketPath
    parser: SplitParser { onRead: function(line) { root.handleSubscriptionLine(line) } }
    onConnectedChanged: {
      if (connected) root.sendSubscription()
      else if (root.online && !root.subscriptionRetry.running && !root.subscriptionKick.running)
        root.subscriptionRetry.start()
    }
    onError: function(errorCode) {
      if (root.online && !root.subscriptionRetry.running) root.subscriptionRetry.start()
    }
  }

  // The SSH forward. Restarted with backoff whenever it exits, which is
  // what happens across sleep, network changes, and remote restarts.
  property Process forward: Process {
    running: root.remote && root.pluginDir !== ""
    command: [
      root.pluginDir + "/bin/agent-forward",
      root.machine.ssh,
      root.socketPath,
      Backend.remoteSocketSuffix(root.machine)
    ]
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.lastError = text.trim().split("\n").pop() }
    onExited: function(code, status) {
      if (root.remote) root.forwardRestart.restart()
    }
  }

  property Timer forwardRestart: Timer {
    interval: 5000
    repeat: false
    onTriggered: if (root.remote && !root.forward.running) root.forward.running = true
  }

  property Timer commandTimeout: Timer {
    interval: 5000
    repeat: false
    onTriggered: root.scheduleReconnect()
  }

  property Timer reconnectTimer: Timer {
    interval: root.reconnectDelayMs
    repeat: false
    onTriggered: {
      root.reconnectDelayMs = Math.min(root.reconnectDelayMs * 2, 30000)
      root.refresh()
    }
  }

  property Timer reconnectKick: Timer {
    interval: 50
    repeat: false
    onTriggered: root.refresh()
  }

  property Timer commandKick: Timer {
    interval: 0
    repeat: false
    onTriggered: root.startNextRequest()
  }

  property Timer subscriptionKick: Timer {
    interval: 0
    repeat: false
    onTriggered: if (root.online && root.socketPath !== "") root.subscriptionSocket.connected = true
  }

  property Timer subscriptionRetry: Timer {
    interval: 1000
    repeat: false
    onTriggered: if (root.online && root.socketPath !== "") root.subscriptionSocket.connected = true
  }

  Component.onCompleted: if (socketPath !== "") refresh()
}
