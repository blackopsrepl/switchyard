---
name: switchyard
description: "Native systemd dashboard for Rails dev environments."
version: 1.0.0
metadata:
  hermes:
    tags: [rails, systemd, quickshell, sway, dashboard]
    category: software-development
---

# Switchyard

Switchyard is a Ruby + QuickShell dashboard that finds and controls the Rails
development environments on a Linux host through systemd.

- Source: `/srv/lab/tools/switchyard`
- CLI: `bin/switchyard` (also `~/.local/bin/switchyard` after `make install-user`)
- Panel: `frontend/quickshell/shell.qml`
- Config: `~/.switchyard/config.json`
- State: `~/.local/state/switchyard/`
- Daemon: a `systemd --user` service named `switchyard`

## Rules that are load-bearing

- `lib/switchyard/core/systemd.rb` is the only module that invokes systemctl or
  journalctl. The panel dispatches CLI commands; it never runs them.
- Detect Rails environments by unit configuration (env markers, ExecStart client,
  working dir under a dev root, `config/application.rb`), never by unit name.
  Always report the matching signals so inclusions are explainable.
- Pair a unit with its port through the unit cgroup, not by grepping `ps`: a
  service started via `bundle exec` shows up as `puma`.
- `active/activating/auto-restart` is a crash-loop, and an enabled unit in
  `failed` is one too. Never render either as "running".
- `sudo -n` is part of the command prefix, not a flag list: prefix + bin must
  yield `sudo -n systemctl …`.
- `state-event.json` must be truncated and rewritten in place; renaming drops
  QuickShell's inotify watch.

## Verifying a panel change

`qmllint` cannot be a CI gate for this panel (the Quickshell `ShellRoot` type only
exists where Quickshell is installed). Load it off-desktop instead:

```sh
make check          # syntax, tests (panel contract), config validation
bin/release-check   # full gate, includes a private headless-sway panel render
```

The release gate starts its own headless Sway with a private `XDG_RUNTIME_DIR`,
loads the panel against a copied state dir, greps the QuickShell log for load
errors, and screenshots the result with `grim`. Never drive the live session.
