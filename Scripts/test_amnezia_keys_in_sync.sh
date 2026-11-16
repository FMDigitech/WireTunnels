#!/bin/bash
# The AmneziaWG-only config keys exist twice: AmneziaWGKeys in the app's config parser
# (validation, engine at import) and RuntimeEngine in the helper (which tool runs a config).
# If the lists differ, the app can call a config AmneziaWG while the helper starts it with
# wg-quick, or the reverse. This test fails when they differ.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARSER="$ROOT_DIR/WireTunnels/Services/WireGuardConfigParser.swift"
LOCATOR="$ROOT_DIR/WireTunnelsHelper/RuntimeConfigLocator.swift"

python3 -I - "$PARSER" "$LOCATOR" <<'PY'
import re, sys

parser = open(sys.argv[1]).read()
locator = open(sys.argv[2]).read()

def block(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]

app_interface = {m.lower() for m in re.findall(
    r'\("([A-Za-z0-9]+)", \.[a-zA-Z0-9]+\)',
    block(parser, 'static let interfaceKinds', 'static let peerKinds'))}
app_peer = {m.lower() for m in re.findall(
    r'\("([A-Za-z0-9]+)", \.[a-zA-Z0-9]+\)',
    block(parser, 'static let peerKinds', 'static func interfaceKind'))}
helper_interface = set(re.findall(
    r'"([a-z0-9]+)"', block(locator, 'static let amneziaInterfaceKeys', 'static let amneziaPeerKeys')))
helper_peer = set(re.findall(
    r'"([a-z0-9]+)"', block(locator, 'static let amneziaPeerKeys', 'static func engine(forConfig')))

def fail(message):
    print("amnezia keys test failed: " + message, file=sys.stderr)
    sys.exit(1)

if not app_interface or not helper_interface:
    fail("could not read the key lists")
if app_interface != helper_interface:
    fail("Interface keys differ: only in the app %s, only in the helper %s"
         % (sorted(app_interface - helper_interface), sorted(helper_interface - app_interface)))
if app_peer != helper_peer:
    fail("Peer keys differ: app %s, helper %s" % (sorted(app_peer), sorted(helper_peer)))
print("AmneziaWG key lists agree (%d interface, %d peer)" % (len(app_interface), len(app_peer)))
PY
