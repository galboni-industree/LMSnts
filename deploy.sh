#!/usr/bin/env bash
# Deploy the NTS Radio plugin to the local Lyrion Music Server install.
# Run this ON THE TARGET DEVICE (the LMS box), not on a dev/CI machine.
#
# Safety design:
#   * Hard-coded, asserted DEST path so --delete can never touch anything but
#     .../Plugins/NTSRadio.
#   * Source is validated (4 required files) before anything is touched.
#   * Best-effort Perl syntax check BEFORE restarting the server.
#   * Existing install is backed up to your home dir before being replaced.
#   * After restart, the log is scanned for plugin errors and rollback is
#     offered if something looks wrong.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/src/NTSRadio"
DEST="/var/lib/squeezeboxserver/Plugins/NTSRadio"
OWNER="squeezeboxserver:nogroup"
SERVICE="lyrionmusicserver"
LOG="/var/log/squeezeboxserver/server.log"
BACKUP_DIR="$HOME/nts-backups"

die() { printf '\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }

# --- Guard rails -----------------------------------------------------------
# Refuse to operate on anything that is not exactly the NTSRadio plugin dir.
case "$DEST" in
	*/Plugins/NTSRadio) : ;;
	*) die "refusing: DEST '$DEST' is not a .../Plugins/NTSRadio path" ;;
esac

[[ -d "$SRC" ]] || die "source not found: $SRC"
for f in install.xml Plugin.pm strings.txt HTML/EN/plugins/NTSRadio/html/icon.png; do
	[[ -e "$SRC/$f" ]] || die "missing required source file: $f"
done
info "source validated: $SRC"

# --- Best-effort syntax check (before we touch the server) -----------------
# Uses the installed LMS libs so base classes resolve. A failure here is
# advisory (false negatives are possible), so we warn rather than abort.
if perl -I/usr/share/squeezeboxserver -c "$SRC/Plugin.pm" >/dev/null 2>&1; then
	info "Plugin.pm syntax check passed"
else
	printf '\033[33mWARN:\033[0m Plugin.pm did not pass the offline syntax check.\n'
	printf '      This can be a false negative (some Slim modules load lazily).\n'
	read -r -p "      Continue with deploy anyway? [y/N] " a
	[[ "${a:-N}" =~ ^[Yy]$ ]] || die "aborted by user before any change was made"
fi

# --- Backup current install (rollback safety) ------------------------------
if [[ -d "$DEST" ]]; then
	mkdir -p "$BACKUP_DIR"
	TS="$(date +%Y%m%d-%H%M%S)"
	BK="$BACKUP_DIR/NTSRadio-$TS.tgz"
	sudo tar -czf "$BK" -C "$(dirname "$DEST")" "$(basename "$DEST")"
	sudo chown "$(id -u):$(id -g)" "$BK" 2>/dev/null || true
	info "backed up existing install -> $BK"
	# Keep only the 5 most recent backups; prune the rest.
	ls -1t "$BACKUP_DIR"/NTSRadio-*.tgz 2>/dev/null | tail -n +6 | xargs -r rm -f
fi

# --- Deploy ----------------------------------------------------------------
sudo mkdir -p "$DEST"
if command -v rsync >/dev/null 2>&1; then
	sudo rsync -a --delete "$SRC"/ "$DEST"/
else
	# Fallback when rsync is unavailable: clean copy.
	sudo rm -rf "${DEST:?}"/*
	sudo cp -a "$SRC"/. "$DEST"/
fi
sudo chown -R "$OWNER" "$DEST"
info "files deployed to $DEST"

# --- Restart ---------------------------------------------------------------
info "restarting $SERVICE ..."
sudo systemctl restart "$SERVICE"

# Give LMS a moment to load plugins, then check the log for our errors.
sleep 8
if [[ -f "$LOG" ]] && sudo grep -iE 'NTSRadio|plugin\.ntsradio' "$LOG" | grep -iqE 'error|fail|can.t locate|died'; then
	printf '\033[33mWARN:\033[0m possible NTSRadio errors found in the log:\n'
	sudo grep -iE 'NTSRadio|plugin\.ntsradio' "$LOG" | grep -iE 'error|fail|can.t locate|died' | tail -10
	echo
	echo "To roll back to the previous version run:  ./undeploy.sh"
	echo "Or restore a backup from: $BACKUP_DIR"
else
	info "no NTSRadio errors detected in the log so far"
fi

echo
info "Done. Tail of the log (Ctrl-C to exit):"
sudo tail -F "$LOG"
