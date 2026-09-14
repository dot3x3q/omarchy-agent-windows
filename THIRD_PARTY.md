# Third-party code

This plugin borrows from two earlier Omarchy plugins for Herdr. Both are MIT
licensed; their notices are reproduced here and in `LICENSE`. Anyone is
welcome to take anything from this repository back in the other direction.

## carlotran4/omarchy-herdr

https://github.com/carlotran4/omarchy-herdr — Copyright (c) 2026 Carlo Tran, MIT.

- `Machine.qml`: the socket lifecycle — one-shot request sockets, a held-open
  `events.subscribe` connection rebuilt when the pane set changes, and the
  bounded reconnect/backoff timers — is adapted from `HerdrModel.qml`.
- `Backend.js`: the status vocabulary, priority order, and
  `state_change_seq` tie-break follow `Herdr.js`.
- `BarWidget.qml`: the panel scaffolding (bar pill, badge row, pane cards,
  keyboard panel wiring) follows the shape of its `BarWidget.qml`.

## jankeesvw/omarchy-herdr

https://github.com/jankeesvw/omarchy-herdr — Copyright (c) 2026 Jankees van Woezik, MIT.

- `bin/agent-window`: the focus-workspace-then-window sequence for Hyprland,
  the argument-shape checks before anything reaches a command line, and the
  `uwsm-app`/`foot` launch are adapted from `bin/herdr-sessions`.

## Herdr and Omarchy

The plugin speaks Herdr's documented JSON socket API and uses Herdr's
`terminal attach`; it runs inside the Omarchy shell using its public plugin
contract and UI components. Neither project's code is copied here.
