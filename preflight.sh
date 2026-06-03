#!/usr/bin/env bash
# Read-only environment checks for the NTS Radio plugin.
# Touches NOTHING on the system: only reads/queries. Safe to run anytime.
# Run this ON THE LMS DEVICE before deploying.
set -uo pipefail

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; WARN=$((WARN+1)); }

API_URL='https://www.nts.live/api/v2/live'
STREAM_URL='https://stream-relay-geo.ntslive.net/stream?client=direct'
UA_PLUGIN='LMS-NTSRadio/1.0.0 (+https://lyrion.org)'
UA_BROWSER='Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'

# Detect the LMS service name across the known variants / init systems.
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

echo "== NTS Radio pre-flight (read-only) =="

# 1) LMS service present?
SERVICE="$(detect_service || true)"
if [[ -n "$SERVICE" ]]; then
	ok "LMS service detected: $SERVICE"
else
	warn "LMS service not auto-detected. Find it with:"
	printf '       systemctl list-units --type=service --all | grep -iE "lyrion|squeeze|logitech|slim|lms"\n'
fi

# 2) Plugins dir present?
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

# 4) JSON available? The plugin prefers JSON::XS but falls back to core JSON::PP,
#    so as long as EITHER is present we are fine.
if perl -MJSON::XS -e 'exit 0' 2>/dev/null; then
	ok "JSON::XS present (system Perl)"
elif perl -MJSON::PP -e 'exit 0' 2>/dev/null; then
	ok "JSON::PP present (core) — plugin will use it as fallback"
else
	bad "neither JSON::XS nor JSON::PP available"
fi

# 5) Stream reachable and audio/mpeg? (network)
CT=$(curl -s --max-time 8 -L -D - -o /dev/null "$STREAM_URL" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tail -1)
if [[ "$CT" == audio/mpeg* ]]; then
	ok "NTS stream reachable (content-type: $CT)"
elif [[ -n "$CT" ]]; then
	warn "NTS stream content-type unexpected: $CT"
else
	warn "NTS stream not reachable from here"
fi

# 6) API reachable AND parseable? Use the SAME parser the plugin uses (Perl
#    JSON::PP) — NOT jq, which may be absent on the device and is irrelevant to
#    the plugin. Test with the plugin's User-Agent; if it fails, retry with a
#    browser UA to pinpoint a bot/UA filter.
api_channels() {  # $1 = user agent -> prints channel count, or empty on failure
	curl -s --max-time 10 -A "$1" "$API_URL" 2>/dev/null | perl -MJSON::PP -0777 -ne '
		my $d = eval { decode_json($_) };
		print scalar(@{$d->{results}}) if $d && ref $d->{results} eq "ARRAY";
	' 2>/dev/null
}
api_code() {      # $1 = user agent -> prints HTTP status
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 -A "$1" "$API_URL" 2>/dev/null
}

LEN_P=$(api_channels "$UA_PLUGIN")
if [[ "$LEN_P" =~ ^[0-9]+$ ]] && (( LEN_P >= 2 )); then
	ok "NTS API reachable & parseable with plugin User-Agent ($LEN_P channels)"
else
	CODE_P=$(api_code "$UA_PLUGIN")
	LEN_B=$(api_channels "$UA_BROWSER")
	if [[ "$LEN_B" =~ ^[0-9]+$ ]] && (( LEN_B >= 2 )); then
		warn "API parseable with a browser UA but NOT the plugin UA (HTTP $CODE_P)."
		printf '       => likely a bot/UA filter. Tell me: the plugin should send a browser-like UA.\n'
	elif [[ "$CODE_P" == "200" ]]; then
		warn "API returned HTTP 200 but the body did not parse as expected JSON."
		printf '       Inspect the body:  curl -s --max-time 10 -A "%s" %s | head -c 400\n' "$UA_PLUGIN" "$API_URL"
	else
		CODE_B=$(api_code "$UA_BROWSER")
		warn "API not reachable (plugin UA -> HTTP $CODE_P, browser UA -> HTTP $CODE_B)."
		printf '       Diagnose DNS/proxy:  curl -sS -v --max-time 10 -A "%s" %s | head -c 400\n' "$UA_BROWSER" "$API_URL"
	fi
fi

echo "-- summary: $PASS ok, $WARN warn, $FAIL fail --"
echo "   (network WARNs are non-fatal: the plugin degrades gracefully and"
echo "    fills metadata in once the API is reachable.)"
exit $(( FAIL > 0 ? 1 : 0 ))
