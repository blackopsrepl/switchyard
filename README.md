# Switchyard

A native dashboard for the Rails development environments on this machine, driven
by systemd.

Switchyard is a Ruby backend plus one QuickShell panel, built like the rest of the
`*-bar-sway` family: a resident action daemon owns every state transition, the
panel renders cached JSON and never runs `systemctl` itself, and a Waybar chip
shows the same projection in the bar.

## What it does

It finds the Rails environments that are already running on the host — or
installed and stopped — and gives them a control surface:

- **Discovery.** Every service unit on the host is classified by its own
  configuration: `RAILS_ENV`/`RACK_ENV`/`BUNDLE_PATH` in the unit environment, the
  Rails client in `ExecStart` (`rails`, `puma`, `rackup`, `sidekiq`,
  `bridgetown`), a working directory under a development root, and a
  `config/application.rb` at that root. The panel shows which signals matched, so
  inclusion is never a black box.
- **Port pairing.** The listening port is found by reading the unit's cgroup and
  matching its pids against `ss`. That is what makes `bundle exec rails server`
  work: the visible process is `puma`, not the ExecStart path.
- **Probe.** Each discovered port gets a bounded TCP connect and HTTP status. A
  Rails app answering 500 is reported as `http 500`, not as healthy.
- **Honest status.** `active/activating/auto-restart` is labelled **crash-loop**,
  not "running". A unit whose current run began seconds after boot is marked
  `(boot)` so "restarts 2478 · up 3h" cannot read as a stable service that has
  restarted 2478 times.
- **Control.** Start, stop, restart, reload, enable/disable at boot, reset a
  failed counter, open the served URL, and read the unit journal — all through the
  daemon, all non-interactive (`sudo -n`).

## Screenshots

![Switchyard panel showing six detected environments, a crash-loop alert, and the
selected unit's facts](docs/assets/switchyard-panel-screenshot.png)

## Current Shape

- CLI entrypoint: `bin/switchyard`
- Backend code: `lib/switchyard/core`
- Runtime code: `lib/switchyard/runtime`
- Human UI: `frontend/quickshell/shell.qml`
- Config: `~/.switchyard/config.json`
- Runtime state: `~/.local/state/switchyard/`
- Local release gate: `bin/release-check`

## Install and run

```sh
make check              # syntax, tests, config validation
make install-user       # ~/.local + a systemd --user daemon
switchyard repos        # this host's Rails environments
switchyard panel        # the QuickShell dashboard
```

`make install-user` installs a `systemd --user` unit for the daemon and a
`switchyard-panel` toggle script. It never creates a system unit: the dashboard
controls system units, it does not add any.

## CLI

```
switchyard repos                        list detected environments (default)
switchyard show UNIT                    everything known about one environment
switchyard logs UNIT [--lines N]        tail the unit journal
switchyard start|stop|restart|reload UNIT
switchyard enable|disable UNIT          enable at boot / remove from boot
switchyard reset-failed UNIT            clear a crash-loop counter
switchyard refresh                      force a scan now
switchyard panel | ui open|close|toggle|status
switchyard waybar render|refresh|panel
switchyard daemon [--once]
switchyard config init|show|validate
switchyard open URL
```

`--json --pretty` on any read command emits the presenter projection as JSON.

## Configuration

`~/.switchyard/config.json` (created by `switchyard config init`):

- `servicePatterns` — unit globs to consider (default `["*.service"]`).
- `excludeUnits` — globs dropped before detection (`systemd-*`, `dracut-*`, …).
- `envMarkers`, `execMarkers`, `workdirMarkers` — the detection signals.
- `kinds` — explicit `{"unit.service": "rails|site|worker|web"}` overrides that
  win over inference, and pin a unit that has no marker at all.
- `pinnedUnits` — units to watch even when detection would skip them.
- `systemctlPrefix` / `journalctlPrefix` — default `sudo -n`, so no action can
  block on a password prompt. Set to `""` when the user can already manage units.
- `probe.enabled`, `probe.timeoutMs`, `probe.hosts`.
- `runtime.refreshSeconds`, `runtime.stateDir`, `runtime.quickShellShell`,
  `runtime.waybarSignal`.

## Waybar chip

Switchyard ships a chip in the SolverForge Linux bar (`solverforge-waybar-switchyard`,
rendered by `switchyard waybar render`), positioned at the head of `modules-right`,
left of `custom/cronbar`. It shows `N/M up`, or `N/M K failing` in the crit colour
when an environment is crash-looping, with the full breakdown in the tooltip.

- Left click opens the panel, middle click rescans, right click prints the status.
- The daemon signals the chip (RTMIN+15) whenever the chip's content actually
  changes, so a restart is visible immediately instead of waiting out the poll
  interval.
- The shim renders an empty chip carrying the `.empty` class when Switchyard is
  not installed, so a machine without it shows no bordered hole in the bar.

## Runtime flow

`switchyard daemon` owns the scan timer, every mutation, and the journal fetch.
The CLI and the panel dispatch actions to it over `daemon.sock`; the daemon
performs the scan and writes `snapshot.json`. A mutation scans immediately rather
than waiting out the refresh interval, so the panel is never a whole interval
behind the click.

State files live in `~/.local/state/switchyard/`:

- `snapshot.json` — the one projection: summary, alerts, units, Waybar chip.
- `ui.json` — panel open/closed, selected unit, filter, query, detail tab.
- `log.json` — the selected unit's journal tail, fetched on demand.
- `state-event.json` — the inotify target; rewritten in place, never renamed.
- `daemon.sock`, `daemon.lock`, `scan.lock`.

## Boundaries

- The panel never runs `systemctl` or `journalctl`; it dispatches CLI commands.
- Waybar reads cached presenter state only.
- `Core::Systemd` is the only place that invokes the systemctl binary, and
  `Core::Detect` is the only place that decides what a Rails environment is.
- No system unit is installed by this project.
