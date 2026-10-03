# Repository Guidelines

## Project Structure

- `bin/switchyard`: Ruby CLI entrypoint.
- `bin/release-check`: local release gate (syntax, tests, QML lint, CLI smoke,
  and a private headless-Sway panel render).
- `lib/switchyard/core`: config, systemctl access, Rails-environment detection,
  port discovery, HTTP probe, formatting, process helpers.
- `lib/switchyard/runtime`: daemon, store, cached state files, presenter,
  QuickShell launcher, Waybar renderer.
- `frontend/quickshell/shell.qml`: the only human-facing UI.
- `packaging/`: user-service install and uninstall scripts.
- `docs/`: architecture and CLI reference.
- `test/`: deterministic Ruby tests.

## Build, Test, Run

- Syntax check: `make syntax`
- Test suite: `ruby -Itest test/run.rb`
- QML lint (local only): `qmllint frontend/quickshell/shell.qml`
- Full gate: `make check`
- Release gate: `bin/release-check`
- One scan without the daemon: `bin/switchyard daemon --once`

## Encoding

- Switchyard runs as a `systemd --user` service, which inherits no locale. Under
  a C/POSIX locale Ruby tags file content US-ASCII, and `JSON.parse` then raises
  `InvalidByteSequenceError` on the first non-ASCII byte in a state file. Every
  config and state-file read must name its encoding explicitly
  (`File.read(path, encoding: Encoding::UTF_8)`), and every write must use
  `File.binwrite` with the payload encoded to UTF-8. `bin/switchyard` also pins
  `Encoding.default_external` before loading the library, so `warn` cannot raise
  on a non-ASCII message.
- Keep the UTF-8 text (the chip's dot separator). Fix the encoding, not the
  string.
- `test/locale_test.rb` runs the CLI as a subprocess under `LC_ALL=C`. The
  failure does not reproduce inside the test process, where the developer's shell
  locale is in effect — which is exactly how it escaped the first time.

## Architecture Rules

- Ruby only for the backend. No second UI stack.
- Standard-library dependencies only. `sudo -n systemctl` is the control path; no
  D-Bus client library.
- QuickShell is the only product UI. Waybar is a cached-state chip and launcher.
- `lib/switchyard/core/systemd.rb` is the only module that invokes the systemctl
  or journalctl binary. Nothing else may shell out to them.
- `lib/switchyard/core/detect.rb` is the only module that decides whether a unit
  is a Rails environment. The classifier must keep returning the signals that
  matched, so the panel can explain its own inclusions.
- The privilege prefix contributes its executable as well as its flags. A prefix
  of `sudo -n` with a bin of `systemctl` must run `sudo -n systemctl …`; treating
  the prefix as flags-only runs `systemctl -n …`, which fails silently and looks
  like "this host has no units".
- Unit discovery resolves `servicePatterns` against `list-unit-files` plus
  `list-units --all`, never by handing the glob to `systemctl show`: the glob only
  matches currently-loaded units, so an installed-but-never-started environment
  would be invisible. Uninstantiated templates (`autovt@.service`) are dropped,
  and `show` is batched, because one un-showable name in a single argv fails the
  whole call.
- A working directory under a development root is a location, not a signal. A
  unit needs a runtime marker — an environment variable, an ExecStart client, or a
  `config/application.rb` — or a `kinds`/`pinnedUnits` override. Otherwise a
  game-server or container stack living in the same tree is reported as a Rails
  environment.
- `DEFAULT_EXEC_MARKERS` is derived from `SITE_EXEC_MARKERS` and
  `WORKER_EXEC_MARKERS`. A client that `infer_kind` can classify but detection
  cannot reach is dead code, and the server it names vanishes from the dashboard
  silently. `config validate` errors on any unreachable kind marker; keep it that
  way rather than duplicating the lists.
- Keep runtime actions daemon-owned. The CLI and the panel dispatch actions;
  `Runtime::Daemon` and `Runtime::Store` own scanning, control, filters,
  selection, and projection.
- A mutation triggers its own scan after the action. Do not make a click wait out
  `refreshSeconds`.
- `state-event.json` is the inotify target: rewrite it in place. Renaming over it
  drops the watch and the panel stops updating.
- Keep the presenter the single source of status. `Runtime::Presenter` maps
  ActiveState/SubState to the status vocabulary (`running`, `crash-loop`,
  `failed`, `stopped`, `unknown`); the panel must not re-derive it.
- `active/activating/auto-restart` is a crash-loop, and an enabled unit in
  `failed` is one too. Reporting either as "running" is the bug this tool exists
  to prevent.
- Port pairing reads the unit cgroup
  (`/sys/fs/cgroup/system.slice/<unit>/cgroup.procs`). The lookup key is the full
  unit name; appending `.service` internally makes every lookup miss.
- The probe reports the HTTP status it got. A 500 is not health; do not collapse
  it into a boolean.

## UI Rules

- Edit `frontend/quickshell/shell.qml` for the human UI.
- The panel reads `snapshot.json`, `ui.json`, `log.json` and `state-event.json`
  and dispatches CLI commands. It must not read cgroups, run `ss`, or invoke
  systemctl.
- Selection, filter, query and detail tab live in `ui.json`, so a row click, the
  keyboard and the CLI agree.
- Position list rows with anchors and explicit band widths. Nested
  `RowLayout`/`ColumnLayout` inside a list delegate let the port column escape the
  row and draw over the detail pane.
- Size sibling `Text` items from an explicit budget, never from each other's
  `width`. A name bound to `descriptionText.width` while the description is bound
  to `nameText.width` is a cycle that resolves in whichever order QML picks, and
  it let a four-character description fragment render.
- The modal height comes from `root.modalHeight()`. Deriving it from implicit
  heights collapses the frame: a `ListView` and a `fillHeight` pane both report a
  near-zero implicit height.
- A description that only fits as `"So…"` is hidden rather than shown. The unit
  name is the row's subject and gets the space.
- Use tooltips and accessible names for icon-only or short-labelled controls.

## Testing

- Add deterministic tests under `test/`.
- Prefer config normalization, `systemctl show` parsing, detection signals, `ss`
  parsing, presenter status mapping, store transactions and Waybar payloads — all
  without a live systemd connection.
- `test/panel_test.rb` asserts the panel's structural contract (no systemctl
  invocation, every rendered presenter field present, only real CLI commands
  dispatched). `qmllint` cannot be a CI gate: the Quickshell `ShellRoot` type only
  exists where Quickshell is installed, so the tool exits non-zero on a clean
  panel. Keep `make lint` local.
- A clean `qmllint` is not proof the panel loads. Load it off-desktop, read its
  log for `ERROR`/`WARN` lines, then screenshot it.
- When changing docs that list commands or architecture, compare against
  `lib/switchyard/cli.rb` and `lib/switchyard/core/config.rb`.

## Agent Notes

- Config lives at `~/.switchyard/config.json`. `make install-user` materializes it
  if absent, so a stale installed config does not silently override new defaults.
- Runtime state lives at `~/.local/state/switchyard/`.
- The daemon is a `systemd --user` service; the units it manages are system units.
  It installs no system unit of its own.
- Verifying the panel: run a private headless Sway (`WLR_BACKENDS=headless`, its
  own `XDG_RUNTIME_DIR`), launch QuickShell against a copied state dir with
  `QT_QPA_PLATFORM=wayland`, and screenshot with `grim`. Never drive the live
  session.
- QuickShell hot-reloads on file change and **keeps rendering the last good
  config** when a reload fails, so a screenshot can silently show stale output.
  Always grep the QuickShell log for `Failed to load configuration` before
  believing a render.
- Before restarting the daemon service, check for stray lock holders
  (`fuser ~/.local/state/switchyard/daemon.lock`). A leftover daemon from a manual
  run holds the lock and makes the service exit-loop with "daemon already
  running", which looks like a service bug and is not one.
- `bin/release-check` leaves its own headless Sway and QuickShell running on the
  success path. Kill the harness pids it created rather than assuming it cleaned
  up.
