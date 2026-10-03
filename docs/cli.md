# CLI reference

Every read command accepts `--json` and `--pretty`. Every command accepts
`--config PATH`; the default is `~/.switchyard/config.json`.

## Read

### `switchyard repos` (aliases: `list`, `ls`, `status`)

Lists the detected environments: unit, kind, status, port, probe result and app
root, followed by any alerts. With `--json` it prints the whole presenter
projection (`summary`, `alerts`, `units`, `chip`).

```
$ switchyard repos
Switchyard - Rails development environments (systemd)
1/6 running  ·  1 failing  ·  1 listening  ·  2478 restarts  ·  scanned 0s ago

UNIT                      KIND             STATUS             PORT    PROBE    WORKDIR
elphame.service           rails            stopped            -       -        /srv/lab/dev/elphame
observer-state.service    rails            stopped            -       -        /srv/lab/hack/rails/observer-state
sabbatic.service          rails            stopped            -       -        /srv/lab/dev/sabbatic
solverforge-ai.service    rails            crash-loop         -       -        /srv/lab/sites/solverforge.ai
solverforge-site.service  site             running (boot)     1313    http 200 /srv/lab/sites/solverforge.org
yuga-planner.service      rails            stopped            -       -        /srv/lab/hack/rails/yuga-planner3

! solverforge-ai.service: crash-looping (2478 restarts, 5s ago)
```

`(boot)` marks a unit whose current run started at host boot.

### `switchyard show UNIT` (alias: `info`)

Everything known about one environment: state, enablement, restarts, uptime, pid,
user, memory, cpu, working directory, app root, port and its owning process, probe
result, the detection signals that matched, and the unit file path.

### `switchyard logs UNIT [--lines N]`

The unit journal (`journalctl -u UNIT -n N`). `--lines` defaults to
`runtime.logLines` from the config.

## Control

```
switchyard start UNIT
switchyard stop UNIT
switchyard restart UNIT
switchyard reload UNIT
switchyard enable UNIT          # enable at boot
switchyard disable UNIT         # remove from boot (does not stop it)
switchyard reset-failed UNIT    # clear the restart counter
switchyard refresh              # force a scan and print the summary
```

Each mutation runs the systemctl verb and then scans immediately. Mutations are
non-interactive (`sudo -n` by default) and never prompt.

## Surface

```
switchyard panel                        open the QuickShell dashboard
switchyard ui open|close|toggle|status
switchyard ui select UNIT               set the panel's selected unit
switchyard ui filter all|running|stopped|failed
switchyard ui filter-query TEXT         set the panel's text filter
switchyard ui tab overview|info|logs    set the panel's detail tab
switchyard waybar render                JSON payload for Waybar
switchyard waybar refresh               ask the daemon to scan
switchyard waybar panel                 open the panel from the chip
switchyard open URL                     open a URL in the browser
```

## Daemon and config

```
switchyard daemon               run the action daemon (foreground)
switchyard daemon --once        one scan, no socket
switchyard config init          write the default config
switchyard config show          print the effective config
switchyard config validate      check paths, binaries and globs
```

`config validate` exits non-zero on errors only; warnings (a missing shell path, a
missing workdir root) are printed but do not fail.

## Exit codes

`0` on success, `1` on a failed action or an invalid argument. A failed systemctl
verb prints the verb, the unit and systemd's own error line.
