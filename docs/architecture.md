# Architecture

Switchyard has four active layers:

1. Ruby CLI in `bin/switchyard`.
2. Core services for config, systemd access, Rails detection, ports, probing.
3. Daemon-owned runtime actions and cached JSON state.
4. Presenter output for the QuickShell panel and the Waybar chip.

## Boundaries

The systemd boundary is `lib/switchyard/core/systemd.rb`. It is the only module
that invokes `systemctl` or `journalctl`. Discovery is the union of
`list-unit-files --type=service` and `list-units --all --type=service`, filtered
by the configured globs in Ruby; `systemctl show '*.service'` is never used, because
it only matches units systemd currently has loaded and would hide an
installed-but-never-started development environment. `show` is issued in batches
of 64 units so a large host cannot overflow the argument list, and one
un-showable name (an uninstantiated template such as `autovt@.service`) cannot
fail a whole batch.

The privilege prefix is a command prefix, not a flag list: `systemctlPrefix:
"sudo -n"` plus `systemctlBin: "systemctl"` runs `sudo -n systemctl …`. The
non-interactive `-n` matters because a dashboard click must never block on a
password prompt.

The detection boundary is `lib/switchyard/core/detect.rb`. A unit is a Rails
environment when its own configuration says so:

- `RAILS_ENV`, `RACK_ENV`, `BUNDLE_PATH` or `BUNDLE_GEMFILE` in the unit
  environment;
- a Rails client in `ExecStart` or its resolved path (`rails`, `puma`, `rackup`,
  `sidekiq`, `bridgetown`);
- a `WorkingDirectory` under one of `workdirMarkers`; or
- a `config/application.rb` at that directory, which also provides the app root
  the panel displays.

`kinds` and `pinnedUnits` override detection for units that carry no marker at
all. The classifier returns every signal that fired, and the panel renders them,
so an inclusion can always be explained or overridden rather than argued with.

The port boundary is `lib/switchyard/core/ports.rb`. Listening sockets come from
`ss -ltnpH`. A socket is paired with a unit by reading
`/sys/fs/cgroup/system.slice/<unit>/cgroup.procs` and intersecting those pids with
the socket owners — which is what makes a service started through
`bundle exec rails server` work, since the visible process is `puma`, not the
ExecStart path. Sockets whose owner is not readable still report their port, with
a pid of `nil`; dropping them would hide a service the operator can see in `ss`.

The probe boundary is `lib/switchyard/core/probe.rb`. It is a bounded TCP connect
plus a one-line HTTP status read. It reports the status code it received: a Rails
app answering 500 is `probeStatus: 500`, not "healthy". The only negative is
"nothing answered in time".

The runtime boundary is `lib/switchyard/runtime/daemon.rb`, `store.rb` and
`state.rb`. The daemon owns the unix action socket, the scan timer, scan
coalescing, every mutation, and the on-demand journal fetch. `Runtime::Store`
holds the transitions; the CLI and the panel only dispatch.

The presentation boundary is `lib/switchyard/runtime/presenter.rb`. It is the
single place that maps systemd's `ActiveState`/`SubState` into the status
vocabulary the UI renders:

| systemd | status |
| --- | --- |
| `active/running` | `running` |
| `activating/auto-restart` | `crash-loop` |
| `failed` (unit enabled) | `crash-loop` |
| `failed` (unit disabled) | `failed` |
| `inactive/dead` | `stopped` |
| `reloading`, `deactivating` | `reloading` |
| anything else | `unknown` |

An enabled unit in `failed` state is crash-looping by definition: systemd will
restart it. Reporting that as "running" is the failure mode this tool exists to
remove. The presenter also computes `sinceBoot` so a unit whose current run began
seconds after the host booted is labelled as such, instead of presenting a boot
start as a long uptime next to a four-digit restart counter.

The frontend boundary is `frontend/quickshell/shell.qml`. It watches JSON files,
dispatches CLI commands, and renders. It does not read cgroups, run `ss`, or
invoke systemctl.

## State

Runtime state defaults to `~/.local/state/switchyard/`.

- `snapshot.json`: the canonical projection — `summary`, `alerts`, `units`, `chip`.
- `ui.json`: panel state (`open`, `selectedUnit`, `filter`, `query`, `detailTab`).
- `log.json`: the selected unit's journal tail, loaded on demand.
- `state-event.json`: the inotify target. It is rewritten in place and never
  renamed, because a rename drops Quickshell's watch and freezes the panel.
- `daemon.sock`, `daemon.lock`, `scan.lock`.

## Flow

A scan runs `unit_names` → `show` → `classify` → `ports.scan` → `probe` →
`build_row` → `Presenter.build_view` → `snapshot.json` → `state-event.json`. The
whole scan is serialized by `scan.lock` so a timer tick and an action-triggered
scan cannot interleave.

A mutation (`start`, `stop`, `restart`, `reload`, `enable`, `disable`,
`reset-failed`) runs the systemctl verb under the configured prefix and then
requests a scan, so the panel and the chip are never a whole refresh interval
behind the click. Scan requests coalesce: a request that arrives while a scan is
running sets a pending flag instead of spawning a second scan.

## UI

The panel is a centered modal overlay over a dimmed backdrop. The header carries
the summary line and any alerts; below it are a text filter, four status chips,
the environment list, and the detail pane for the selected unit. The detail pane
has three tabs:

- **Overview** — status, boot enablement, restarts, uptime, main pid, user,
  memory, cpu, app root, port, probe result, and the detection signals that
  matched. A crash-looping unit gets a short explanation of what that counter
  means and what to do.
- **Unit** — working directory, unit file path, unit-file state, kind, load state,
  and the pids paired to its port.
- **Logs** — the journal tail, fetched on demand.

Row clicks and the keyboard write the selection into `ui.json`, so the CLI
(`switchyard ui select …`) and the panel cannot disagree. The modal height is
computed from known parts rather than implicit heights: a `ListView` and a
`fillHeight` pane both report a near-zero implicit height, which collapses the
frame until rows clip into each other.

Waybar reads cached presenter state only. It never scans: refresh is a daemon
action. The chip reports `N/M up` or `N/M K failing`, with `has-failures` and
`has-restarts` classes.
