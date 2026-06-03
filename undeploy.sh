#!/usr/bin/env bash
# Cleanly remove the NTS Radio plugin and return LMS to a pristine state.
# Removes ONLY .../Plugins/NTSRadio and restarts the server. Your backups in
# ~/nts-backups are left untouched (delete them by hand if you want zero trace).
set -euo pipefail

DEST="/var/lib/squeezeboxserver/Plugins/NTSRadio"

die() { printf '\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }

detect_service() {
	local s
	for s in lyrionmusicserver squeezeboxserver logitechmediaserver slimserver lms; do
		if systemctl cat "$s" >/dev/null 2>&1 || systemctl status "$s" >/dev/null 2>&1; then
			echo "$s"; return 0
		fi
	done
	for s in lyrionmusicserver squeezeboxserver logitechmediaserver; do
		[[ -x "/etc/init.d/$s" ]] && { echo "$s"; return 0; }
	done
	return 1
}

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

SERVICE="$(detect_service || true)"
if [[ -n "$SERVICE" ]]; then
	info "restarting $SERVICE ..."
	sudo systemctl restart "$SERVICE" || \
		echo "      (could not restart automatically — restart LMS manually)"
else
	printf '\033[33mWARN:\033[0m LMS service not detected — restart LMS manually to finish removal.\n'
fi
info "done — the plugin is gone and LMS is back to its previous state."
