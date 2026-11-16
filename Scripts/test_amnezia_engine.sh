#!/bin/bash
# The helper chooses the engine that runs a tunnel. These checks pin the wiring: every place
# that used to assume wg-quick and /var/run/wireguard must follow the engine, and status must
# never hand the app an unreduced awg dump (its interface line carries the private key).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"
LOCATOR="$ROOT_DIR/WireTunnelsHelper/RuntimeConfigLocator.swift"
DNS="$ROOT_DIR/WireTunnelsHelper/DNSRecoveryService.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
INVENTORY="$ROOT_DIR/WireTunnels/Services/TunnelInventoryIntegration.swift"

fail() { echo "amnezia engine test failed: $*" >&2; exit 1; }

# A chosen engine reaches the helper only as the marker the app adds to the staged copy.
grep -q 'engine: liveTunnel.engine' "$MANAGER" ||
    fail "connecting must stage the config for the tunnel's engine"
grep -q 'EngineMarker.addingAmneziaWGMarker' "$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift" ||
    fail "staging an AmneziaWG tunnel must add the engine marker"
grep -q 'EngineMarker.isMarker' "$LOCATOR" ||
    fail "the helper must honour the engine marker"

# Start and stop run the engine's own quick script, with the engine's own userspace tool.
grep -q 'RuntimeEngine.engine(forConfig:' "$HELPER" ||
    fail "starting a tunnel must pick the engine from the validated config"
grep -q 'systemBinDir.appendingPathComponent(engine.quickTool)' "$HELPER" ||
    fail "up/down must run the engine's quick script"
grep -q 'RuntimeEngine.engine(runningAlias:' "$HELPER" ||
    fail "stopping a tunnel must use the engine that is running it"
grep -q 'systemBinDir.appendingPathComponent(engine.userspaceTool).path' "$HELPER" ||
    fail "the userspace implementation must follow the engine"
! grep -q 'executable: systemBinDir.appendingPathComponent("wg-quick")' "$HELPER" ||
    fail "no start/stop path may hard-code wg-quick"
grep -q 'wireGuardEnvironment(for: engine)' "$HELPER" ||
    fail "the environment must be built for the tunnel's engine"

# Status covers both engines and reduces awg's dump before it leaves the helper.
grep -q 'RuntimeStatusDump.redactedAmnezia(awg.stdout)' "$HELPER" ||
    fail "awg status must be reduced to wg's shape before it reaches the app"
grep -q 'RuntimeStatusDump.redactedWireGuard(wg.stdout)' "$HELPER" ||
    fail "wg status must keep its redaction"
! grep -q 'awg.stdout)' <(grep -v 'redactedAmnezia' "$HELPER") ||
    fail "raw awg output must never be passed on"
test "$(grep -c 'inAll: RuntimeEngine.runtimeDirectories' "$HELPER")" -ge 3 ||
    fail "runtime config discovery must cover both engines"
! grep -q 'in: URL(fileURLWithPath: "/var/run/wireguard")' "$HELPER" ||
    fail "no discovery path may look only at /var/run/wireguard"
grep -q 'hasUserspaceSockets(inAny:' "$HELPER" ||
    fail "the tools-unavailable check must see sockets of every engine"

# A DNS owner is judged by its own engine's directory, or recovery would restore DNS under a live tunnel.
grep -q 'runtimeDirectories: \[URL\] = RuntimeEngine.runtimeDirectories' "$DNS" ||
    fail "DNS recovery must default to every engine's runtime directory"
grep -q 'runtimeDirectories.contains { isAlive(owner, in: $0) }' "$DNS" ||
    fail "DNS ownership must be provable from any engine's directory"

# Shared tunnels carry their engine, and the app does not offer inventory protection on AmneziaWG.
grep -q 'engine: metadata.usesAmneziaWG ? "amneziawg" : "wireguard"' "$HELPER" ||
    fail "a new shared tunnel must record its engine"
grep -q 'records\[index\].engine == nil' "$HELPER" ||
    fail "shared tunnels saved before the field existed must be filled in"
grep -q 'RuntimeEngine.engine(forConfig: text) == .amneziaWG' "$HELPER" ||
    fail "the helper must refuse inventory protection on AmneziaWG"
grep -q 'tunnels\[index\].engine == .amneziaWG' "$INVENTORY" ||
    fail "the app must refuse inventory protection on AmneziaWG"
grep -q 'TunnelShutdownRuntimeProbe.hasNoRuntimeEvidence()' "$MANAGER" ||
    fail "quitting without the helper must look at every engine's runtime directory"

echo "AmneziaWG engine wiring checks passed"
