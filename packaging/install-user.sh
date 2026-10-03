#!/usr/bin/env bash
#
# Wire the Switchyard daemon and the panel launcher for the current user.
# Safe to re-run: every step is written idempotently.
#
# Nothing here touches a system systemd unit. The dashboard manages system units
# through `sudo -n systemctl`; it does not install any of its own.
set -euo pipefail

command -v systemctl >/dev/null 2>&1 || { echo "switchyard: systemctl is not available" >&2; exit 1; }

# The panel and daemon are user processes, so they live in the user manager.
UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "$UNIT_DIR"

cat >"$UNIT_DIR/switchyard.service" <<'UNIT'
[Unit]
Description=Switchyard daemon (Rails dev environment scans over systemd)
After=default.target

[Service]
Type=simple
ExecStart=%h/.local/bin/switchyard daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now switchyard.service

echo "switchyard: user service enabled (systemctl --user status switchyard)"

# A launcher the Omarchy shell binding and any manual keybind can call.
BIN="${HOME}/.local/bin/switchyard"

# Materialize the config so it is discoverable and editable rather than implicit.
if [ ! -f "${HOME}/.switchyard/config.json" ]; then
  "$BIN" config init >/dev/null
  echo "switchyard: wrote ${HOME}/.switchyard/config.json"
fi

cat >"$BIN-panel" <<LAUNCHER
#!/usr/bin/env bash
# Toggle the Switchyard panel.
set -euo pipefail
exec "$BIN" ui toggle
LAUNCHER
chmod +x "$BIN-panel"

# Register the panel with the Omarchy shell layout if that CLI is present.
if command -v omarchy-shell >/dev/null 2>&1; then
  echo "switchyard: omarchy-shell found; add a custom binding for ${BIN}-panel if you want a key"
fi

echo "switchyard: installed. Panel: ${BIN} panel   Toggle: ${BIN}-panel"
