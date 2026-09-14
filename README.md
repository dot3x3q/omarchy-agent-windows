# Agent Windows

Persistent [Herdr](https://herdr.dev) panes, on any machine, as first-class
Omarchy windows — with live agent status in the bar.

Herdr keeps panes (and the coding agents in them) running in a background
server that survives closed windows, dropped SSH, and a laptop lid. Its usual
face is a terminal multiplexer TUI. This plugin dissolves that: every pane
becomes its own Hyprland window when you want it, tiled by Hyprland like any
other window, and the bar tells you which agents need you before you open
anything.

- **Bar badge** — counts of agents that are *blocked* (waiting on you),
  *done* (finished while you weren't looking), and *working*. Quiet when
  everything is idle.
- **Panel** — every pane on every configured machine, most urgent first,
  with machine, agent, directory, and title. Machines show online/offline.
- **Click a pane** — its window comes to the front. If it has none, one is
  opened running a direct attach to that pane (over `ssh -t` for a remote
  machine). Close the window and the pane keeps running.
- **Event-driven** — status updates arrive through Herdr's `events.subscribe`
  over the socket. Nothing polls on a timer.
- **Remote machines** — each SSH machine's Herdr socket is forwarded to a
  local unix socket (`ssh -L`), kept alive with backoff across sleep and
  network changes. No Herdr TUI needs to be open anywhere.

## Requirements

- Omarchy 4 (Quickshell shell), `foot`, `jq`
- Herdr 0.8+ on each machine you list (0.9.0 is what this was built against)
- Passwordless SSH (`BatchMode`) to each remote machine

## Install

```bash
omarchy plugin add https://github.com/rubys/omarchy-agent-windows --enable
```

Then list your machines. The `machines` setting is JSON and lives in the
widget's entry in `~/.config/omarchy/shell.json` (the file hot-reloads):

```json
{
  "id": "rubys.agent-windows",
  "machines": [
    { "label": "local" },
    { "label": "mini", "ssh": "mini.local" },
    { "label": "vps",  "ssh": "deploy@vps.example.com", "session": "work" }
  ]
}
```

| key | meaning |
|---|---|
| `label` | Short name shown in the panel and used in window app-ids. Required. |
| `ssh` | SSH target. Omit for the local machine. |
| `session` | Herdr named session (default `default`). |
| `socketPath` | Override the local socket path entirely. |
| `remoteSocket` | Override the remote socket path (relative to the remote home, or absolute). |

Other settings (`showIcon`, `showShells`) are in the bar's settings screen.

## Windows

Each pane window has app-id `agent-windows.<label>.<terminal-id>`, so window
rules can match them:

```lua
-- ~/.config/hypr/windows.lua
hl.rule({ match = { class = "^agent%-windows%." }, workspace = 4 })
```

Inside a window, `ctrl+b q` detaches (closes the window, pane keeps running)
and `ctrl+b ctrl+b` sends a literal `ctrl+b`. If the SSH link drops the
window offers to reconnect with one keypress.

## How it fits together

```
 Omarchy bar ── BarWidget.qml ── Machine.qml ×N ── unix socket ── Herdr server (local)
                     │                 │
                     │                 └── bin/agent-forward ── ssh -L ── Herdr server (remote)
                     │
                     └── bin/agent-window ── hyprctl / foot -e ssh -t … herdr terminal attach
```

`Machine.qml` and `Backend.js` are the only files that know Herdr's protocol;
everything else consumes a small normalized pane record. A different backend
(tmux control mode, say) would slot in there with `status` reported as
`unknown`.

## Development

Edit in place under `~/.config/omarchy/plugins/rubys.agent-windows/`. Note
that the shell's hot-reload keeps an already-registered bar widget's compiled
component, so QML changes take effect after `omarchy restart shell`
(`omarchy plugin disable`/`enable` also re-creates it, but rewrites the layout
entry and drops your `machines` setting).

```bash
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell BarWidget.qml Machine.qml
bash -n bin/agent-forward bin/agent-window
```

## Relationship to other plugins

Two earlier plugins put Herdr in the Omarchy bar, and this one borrows from
both — see [THIRD_PARTY.md](THIRD_PARTY.md):

- [carlotran4/omarchy-herdr](https://github.com/carlotran4/omarchy-herdr) —
  event-driven status for one local session; clicking focuses the Herdr TUI.
- [jankeesvw/omarchy-herdr](https://github.com/jankeesvw/omarchy-herdr) —
  every local session in one panel, with window management.

The difference here is the thesis: multiple machines, and panes as windows
rather than the TUI as the window. Anything in this repository is free to be
taken back into either of them.
