#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
SETTINGS="$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"
LIST="$ROOT_DIR/WireTunnels/Views/Dashboard/TunnelListView.swift"

grep -q 'func redetectEnvironment() async' "$MANAGER" ||
    { echo "TunnelManager must expose a dedicated environment re-detect action" >&2; exit 1; }
grep -q 'guard !isLoading else' "$MANAGER" ||
    { echo "Environment re-detection must reject overlapping operations" >&2; exit 1; }
grep -q 'Environment re-detection complete' "$MANAGER" ||
    { echo "Environment re-detection must log a visible completion point" >&2; exit 1; }
grep -q 'await refreshStatus(reportError: false)' "$MANAGER" ||
    { echo "Initial login refresh must not show a transient helper error before retry" >&2; exit 1; }
test "$(grep -c 'await refreshStatus(reportError: false)' "$MANAGER")" -ge 2 ||
    { echo "Initial login refresh retry must also stay silent" >&2; exit 1; }
grep -q 'guard !isShuttingDown, !isLoading, !needsSetup else { return }' "$MANAGER" ||
    { echo "Auto-connect must wait until helper/runtime setup is complete" >&2; exit 1; }
grep -q 'guard !self.isLoading else { continue }' "$MANAGER" ||
    { echo "Polling must not refresh status while launch setup is still running" >&2; exit 1; }
grep -q 'guard tunnelManager.isInitialized else { return }' "$LIST" ||
    { echo "Tunnel list refresh must not surface helper errors during launch" >&2; exit 1; }
LOCATOR="$ROOT_DIR/WireTunnels/Services/WireGuardToolLocator.swift"
! grep -q 'bundledManifest' <(sed -n '/func detect()/,/^    }/p' "$LOCATOR") ||
    { echo "Missing bundled manifest must not force setup when installed tools are valid" >&2; exit 1; }
# Tools are installed by the helper itself; a helper that cannot launch (stale launchd
# registration) is the failure the user sees, from both setup and re-detection.
grep -q 'static let staleRegistrationRecoveryMessage' "$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift" &&
test "$(grep -c 'WireGuardCommandService.staleRegistrationRecoveryMessage' "$MANAGER")" -ge 2 ||
    { echo "Tool install timeouts must surface stale helper recovery guidance" >&2; exit 1; }
grep -q 'await tunnelManager.redetectEnvironment()' "$SETTINGS" ||
    { echo "Settings must use the dedicated environment re-detect action" >&2; exit 1; }
grep -q 'isRedetecting || tunnelManager.isLoading' "$SETTINGS" ||
    { echo "Re-detect must be disabled while the manager is busy" >&2; exit 1; }

echo "Environment re-detection is isolated and bounded"
