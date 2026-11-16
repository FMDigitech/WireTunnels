#!/bin/bash
# A profile's proxy and the DNS cache flush run as root in the helper. These checks pin the
# guarantees that matter: only administrators change the proxy, the helper validates what the app
# sent, the user's own settings are journaled before they change, and the protocol files agree.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"
SERVICE="$ROOT_DIR/WireTunnelsHelper/ProxyProfileService.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/NetworkProfileManager.swift"
APP_PROTOCOL="$ROOT_DIR/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift"
HELPER_PROTOCOL="$ROOT_DIR/WireTunnelsHelper/WireguardHelperProtocol.swift"
COMMAND_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"

fail() { echo "profile proxy test failed: $*" >&2; exit 1; }

cmp -s "$APP_PROTOCOL" "$HELPER_PROTOCOL" || fail "the two copies of the helper protocol differ"
for method in applyProfileProxy releaseProfileProxy flushDNSCache; do
    grep -q "func $method" "$APP_PROTOCOL" || fail "$method is missing from the protocol"
    grep -q "func $method" "$HELPER" || fail "the helper does not implement $method"
done

# Proxy changes are for administrators, and the helper checks the settings itself.
python3 -I - "$HELPER" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for name in ("applyProfileProxy", "releaseProfileProxy"):
    body = text[text.index("func " + name):]
    body = body[:body.index("\n    }\n")]
    if "callerIsAdministrator" not in body:
        sys.exit(name + " must be reserved for administrators")
apply = text[text.index("func applyProfileProxy"):]
apply = apply[:apply.index("\n    }\n")]
if ".problem" not in apply:
    sys.exit("the helper must validate the proxy settings it receives")
PY

# The user's settings are saved before the first change, and a second profile builds on them.
python3 -I - "$SERVICE" <<'PY'
import sys
text = open(sys.argv[1]).read()
if text.index("writeJournal(created)") > text.index("SCNetworkProtocolSetConfiguration(proxies, settings"):
    sys.exit("the journal must be written before the proxy changes")
if "journal?.previousConfiguration" not in text:
    sys.exit("a profile must be built on the original settings, not on the previous profile's")
if "existing.serviceID != serviceID" not in text:
    sys.exit("moving to another network service must restore the old one first")
PY

# The app applies a proxy only when it changes, and puts it back when the app quits.
grep -q 'guard appliedProxy != .some(wanted)' "$MANAGER" || fail "an unchanged proxy must not be rewritten"
grep -q 'releaseProfileProxy' "$MANAGER" || fail "the proxy must be released"
grep -q 'flushAfterDNSChange' "$MANAGER" || fail "a DNS change must flush the cache"

# The protocol revision changed, so an older helper (without these calls) gets replaced.
grep -q 'proxy-flush"' "$HELPER" || fail "the helper protocol revision must name the new calls"
grep -q 'proxy-flush"' "$COMMAND_SERVICE" || fail "the app must expect the new helper protocol revision"

echo "PASS: profile proxy and DNS flush wiring"
