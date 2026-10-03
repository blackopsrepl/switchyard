#!/usr/bin/env bash
#
# Remove the Switchyard user service. Leaves the state directory in place: it is
# the dashboard's own cache and deleting it is the operator's call.
set -euo pipefail

systemctl --user disable --now switchyard.service 2>/dev/null || true
rm -f "${HOME}/.config/systemd/user/switchyard.service"
systemctl --user daemon-reload 2>/dev/null || true
rm -f "${HOME}/.local/bin/switchyard-panel"

echo "switchyard: user service removed (state kept at ~/.local/state/switchyard)"
