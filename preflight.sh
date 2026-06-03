#!/usr/bin/env bash
# Read-only environment checks for the NTS Radio plugin.
# Touches NOTHING on the system: only reads/queries. Safe to run anytime.
# Run this ON THE LMS DEVICE before deploying.
set -uo pipefail

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; WARN=$((WARN+1)); }

echo "== NTS Radio pre-flight (read-only) =="

# 1) LMS service present?
if systemctl list-unit-files 2>/dev/null | grep -q '^lyrionmusicserver\.service'; then
	ok "lyrionmusicserver.service exists"
else
	warn "lyrionmusicserver.service not found (check the exact service name)"
fi

# 2) Plugins dir present and known owner?
PDIR="/var/lib/squeezeboxserver/Plugins"
if [[ -d "$PDIR" ]]; then
	ok "plugins dir exists: $PDIR"
else
	bad "plugins dir missing: $PDIR"
fi

# 3) Perl SSL available?
if perl -MIO::Socket::SSL -e 'exit 0' 2>/dev/null; then
	V=$(perl -MIO::Socket::SSL -e 'print $IO::Socket::SSL::VERSION' 2>/dev/null)
	ok "IO::Socket::SSL present ($V)"
else
	bad "IO::Socket::SSL missing — HTTPS to NTS will fail"
fi

# 4) JSON::XS available (used by the plugin)?
if perl -MJSON::XS -e 'exit 0' 2>/dev/null; then
	ok "JSON::XS present"
else
	bad "JSON::XS missing — plugin cannot parse the API"
fi

# 5) Stream reachable and audio/mpeg? (network)
CT=$(curl -s --max-time 8 -L -D - -o /dev/null 'https://stream-relay-geo.ntslive.net/stream?client=direct' 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tail -1)
if [[ "$CT" == audio/mpeg* ]]; then
	ok "NTS 1 stream reachable (content-type: $CT)"
elif [[ -n "$CT" ]]; then
	warn "NTS 1 stream content-type unexpected: $CT"
else
	warn "NTS 1 stream not reachable from here (check network/firewall)"
fi

# 6) API reachable and >=2 channels? (network)
LEN=$(curl -s --max-time 10 'https://www.nts.live/api/v2/live' 2>/dev/null | jq -r '.results | length' 2>/dev/null)
if [[ "$LEN" =~ ^[0-9]+$ ]] && (( LEN >= 2 )); then
	ok "NTS API reachable ($LEN channels)"
else
	warn "NTS API not reachable / unexpected (metadata will use fallbacks until it recovers)"
fi

echo "-- summary: $PASS ok, $WARN warn, $FAIL fail --"
# Only hard failures (missing Perl modules / dirs) block a clean install.
# Network WARNs are non-fatal: the plugin degrades gracefully.
exit $(( FAIL > 0 ? 1 : 0 ))
