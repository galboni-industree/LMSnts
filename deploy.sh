#!/usr/bin/env bash
# Deploy the NTS Radio plugin to the local Lyrion Music Server install.
# Run this ON THE TARGET DEVICE (the LMS box), not on a dev/CI machine.
set -euo pipefail

# Resolve the source dir relative to this script so it works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/src/NTSRadio"
DEST="/var/lib/squeezeboxserver/Plugins/NTSRadio"

if [[ ! -d "$SRC" ]]; then
	echo "Source not found: $SRC" >&2
	exit 1
fi

sudo mkdir -p "$DEST"
sudo rsync -a --delete "$SRC"/ "$DEST"/
sudo chown -R squeezeboxserver:nogroup "$DEST"
sudo systemctl restart lyrionmusicserver

echo "Deploy completato. Tail del log (Ctrl-C per uscire):"
sudo tail -F /var/log/squeezeboxserver/server.log
