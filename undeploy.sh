#!/usr/bin/env bash
# Cleanly remove the NTS Radio plugin and return LMS to a pristine state.
# Removes ONLY .../Plugins/NTSRadio and restarts the server. Your backups in
# ~/nts-backups are left untouched (delete them by hand if you want zero trace).
set -euo pipefail

DEST="/var/lib/squeezeboxserver/Plugins/NTSRadio"
SERVICE="lyrionmusicserver"

die() { printf '\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }

# Guard rail: never rm anything that isn't the NTSRadio plugin dir.
case "$DEST" in
	*/Plugins/NTSRadio) : ;;
	*) die "refusing: DEST '$DEST' is not a .../Plugins/NTSRadio path" ;;
esac

if [[ -d "$DEST" ]]; then
	sudo rm -rf "${DEST:?}"
	info "removed $DEST"
else
	info "nothing to remove ($DEST not present)"
fi

info "restarting $SERVICE ..."
sudo systemctl restart "$SERVICE"
info "done — the plugin is gone and LMS is back to its previous state."
