// Pure helpers: status vocabulary, the normalized pane record every other
// file consumes, and the socket/subscription shapes for Herdr.
//
// Status vocabulary, priority order, and the tie-break rule follow
// carlotran4/omarchy-herdr (MIT) - see THIRD_PARTY.md.
.pragma library

var STATUS_ORDER = ["blocked", "done", "working", "unknown", "idle", "shell"]
var STATUS_LABELS = {
  blocked: "Needs you",
  done: "Done",
  working: "Working",
  unknown: "Unknown",
  idle: "Ready",
  shell: "Shell"
}
var STATUS_ICONS = {
  blocked: "󰀦",
  done: "󰄬",
  working: "󰔟",
  unknown: "󰘥",
  idle: "󰒲",
  shell: ""
}
// Which states earn a badge in the bar. Working is shown so a glance says
// "something is happening"; idle and shell are the quiet baseline.
var BADGE_ORDER = ["blocked", "done", "working"]

// A pane with no agent in it is a shell. Herdr reports agent_status only
// when it has an occupant to classify; a status on a pane without an agent
// is stale and is not trusted.
function normalizeStatus(pane) {
  if (!pane || !pane.agent) return "shell"
  var value = String(pane.agent_status || "unknown")
  return STATUS_ORDER.indexOf(value) >= 0 && value !== "shell" ? value : "unknown"
}

function priority(status) {
  var index = STATUS_ORDER.indexOf(status)
  return index < 0 ? STATUS_ORDER.indexOf("unknown") : index
}

// The one record the UI and the window script see. Everything Herdr-specific
// stays in this file and Machine.qml.
function normalizePane(machine, pane) {
  var status = normalizeStatus(pane)
  return {
    machine: machine.label,
    ssh: machine.ssh || "",
    session: machine.session || "default",
    pane_id: String(pane.pane_id || ""),
    terminal_id: String(pane.terminal_id || ""),
    workspace_id: String(pane.workspace_id || ""),
    tab_id: String(pane.tab_id || ""),
    agent: String(pane.agent || ""),
    name: String(pane.name || ""),
    title: String(pane.terminal_title_stripped || pane.terminal_title || pane.title || ""),
    cwd: String(pane.foreground_cwd || pane.cwd || ""),
    status: status,
    seq: Number(pane.state_change_seq || 0)
  }
}

function counts(panes) {
  var result = { blocked: 0, done: 0, working: 0, unknown: 0, idle: 0, shell: 0 }
  var rows = panes || []
  for (var i = 0; i < rows.length; i++) result[rows[i].status]++
  return result
}

function sortedPanes(panes) {
  return (panes || []).slice().sort(function(a, b) {
    var statusDelta = priority(a.status) - priority(b.status)
    if (statusDelta !== 0) return statusDelta
    var machineDelta = a.machine.localeCompare(b.machine)
    if (machineDelta !== 0) return machineDelta
    return paneLabel(a).toLowerCase().localeCompare(paneLabel(b).toLowerCase())
  })
}

// Highest priority first; among equals, the one that changed most recently.
function attentionPane(panes) {
  var rows = panes || []
  if (rows.length === 0) return null
  return rows.slice().sort(function(a, b) {
    var statusDelta = priority(a.status) - priority(b.status)
    if (statusDelta !== 0) return statusDelta
    return b.seq - a.seq
  })[0]
}

function paneLabel(pane, maxLength) {
  var text = pane.title || pane.name || pane.agent || basename(pane.cwd) || pane.pane_id || "pane"
  var limit = maxLength || 40
  return text.length <= limit ? text : text.slice(0, limit - 1) + "…"
}

function basename(path) {
  if (!path) return ""
  var parts = String(path).split("/").filter(function(p) { return p !== "" })
  return parts.length ? parts[parts.length - 1] : "/"
}

function shortenPath(rawPath, maxLength) {
  if (!rawPath) return ""
  var path = String(rawPath).replace(/^\/(?:home|Users)\/[^/]+(?=\/|$)/, "~")
  var limit = maxLength || 48
  if (path.length <= limit) return path
  var parts = path.split("/")
  return "…/" + parts.slice(-2).join("/")
}

// Where this machine's Herdr socket is reachable on the local filesystem.
// Local sessions use Herdr's own paths; SSH machines get a forwarded socket
// under the runtime dir, which bin/agent-forward keeps alive.
function localSocketPath(machine, home, runtimeDir) {
  if (machine.socketPath) return String(machine.socketPath).replace(/^~(?=\/)/, home)
  if (machine.ssh) return runtimeDir + "/agent-windows/" + machine.label + ".sock"
  var name = String(machine.session || "default").trim()
  if (name === "" || name === "default") return home + "/.config/herdr/herdr.sock"
  return home + "/.config/herdr/sessions/" + name + "/herdr.sock"
}

// The remote-side path, relative to the remote home; agent-forward resolves
// $HOME over there because ssh -L does not expand ~ on the remote.
function remoteSocketSuffix(machine) {
  if (machine.remoteSocket) return String(machine.remoteSocket)
  var name = String(machine.session || "default").trim()
  if (name === "" || name === "default") return ".config/herdr/herdr.sock"
  return ".config/herdr/sessions/" + name + "/herdr.sock"
}

function paneKey(panes) {
  return (panes || []).map(function(p) { return p.pane_id })
    .filter(function(id) { return id !== "" }).sort().join("\n")
}

// Lifecycle events are subscribed globally; state changes per known pane
// (Herdr 0.9 requires a pane_id on those). Any event is treated as an
// invalidation and answered with a fresh pane.list.
function subscriptions(panes) {
  var list = [
    { type: "pane.created" },
    { type: "pane.closed" },
    { type: "pane.exited" },
    { type: "pane.agent_detected" },
    { type: "pane.moved" }
  ]
  var rows = panes || []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].pane_id) {
      list.push({ type: "pane.agent_status_changed", pane_id: rows[i].pane_id })
      list.push({ type: "pane.updated", pane_id: rows[i].pane_id })
    }
  }
  return list
}

// Parse the machines setting defensively: it is free-form JSON in shell.json.
function machinesFrom(raw) {
  var rows = Array.isArray(raw) ? raw : []
  var out = []
  var seen = {}
  for (var i = 0; i < rows.length; i++) {
    var m = rows[i] || {}
    var label = String(m.label || (m.ssh ? m.ssh : "local")).trim()
    if (label === "" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(label) || seen[label]) continue
    seen[label] = true
    out.push({
      label: label,
      ssh: String(m.ssh || "").trim(),
      session: String(m.session || "default").trim() || "default",
      socketPath: String(m.socketPath || "").trim(),
      remoteSocket: String(m.remoteSocket || "").trim()
    })
  }
  return out
}

function tooltip(panes, machines) {
  var rows = sortedPanes(panes)
  var offline = machines.filter(function(m) { return !m.online }).map(function(m) { return m.label })
  var lines = []
  if (rows.length === 0) lines.push("Agent Windows · no panes")
  else lines.push("Agent Windows · " + rows.length + " pane" + (rows.length === 1 ? "" : "s"))
  if (offline.length) lines.push("offline: " + offline.join(", "))
  lines.push("")
  for (var i = 0; i < Math.min(rows.length, 12); i++) {
    var p = rows[i]
    lines.push(STATUS_ICONS[p.status] + "  " + STATUS_LABELS[p.status] + "  " + p.machine + " · " + paneLabel(p))
  }
  if (rows.length > 12) lines.push("… and " + (rows.length - 12) + " more")
  lines.push("", "Left: panel · Middle: open priority pane · Right: refresh")
  return lines.join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    STATUS_ORDER: STATUS_ORDER, STATUS_LABELS: STATUS_LABELS, BADGE_ORDER: BADGE_ORDER,
    normalizeStatus: normalizeStatus, normalizePane: normalizePane, counts: counts,
    sortedPanes: sortedPanes, attentionPane: attentionPane, paneLabel: paneLabel,
    shortenPath: shortenPath, localSocketPath: localSocketPath,
    remoteSocketSuffix: remoteSocketSuffix, paneKey: paneKey,
    subscriptions: subscriptions, machinesFrom: machinesFrom, tooltip: tooltip
  }
}
