#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NETMON="$ROOT_DIR/WireTunnels/Services/NetworkMonitorService.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"

grep -q 'var onSystemWake: (() async -> Void)?' "$NETMON" ||
    { echo "NetworkMonitorService must expose an onSystemWake callback" >&2; exit 1; }
grep -q 'NSWorkspace.didWakeNotification' "$NETMON" ||
    { echo "NetworkMonitorService must observe NSWorkspace.didWakeNotification" >&2; exit 1; }
grep -q 'NSWorkspace.shared.notificationCenter.removeObserver(self)' "$NETMON" ||
    { echo "NetworkMonitorService must remove the wake observer in deinit" >&2; exit 1; }

grep -q 'networkMonitor.onSystemWake = { \[weak self\] in' "$MANAGER" ||
    { echo "TunnelManager must wire onSystemWake in init()" >&2; exit 1; }
grep -q 'func handleSystemWake() async' "$MANAGER" ||
    { echo "TunnelManager must expose a dedicated system-wake handler" >&2; exit 1; }
grep -q 'guard !isShuttingDown, !isLoading, !needsSetup else { return }' "$MANAGER" ||
    { echo "System wake handling must wait until launch setup is complete" >&2; exit 1; }
grep -q 'func reconnectAfterWake(_ tunnel: Tunnel) async' "$MANAGER" ||
    { echo "TunnelManager must restart each active tunnel's interface on wake" >&2; exit 1; }
grep -q 'guard !connectingTunnels.contains(liveTunnel.id), !disconnectingTunnels.contains(liveTunnel.id) else' "$MANAGER" ||
    { echo "Wake reconnect must reuse the connectingTunnels race guard" >&2; exit 1; }
grep -q 'try await commandService.stopTunnel(configPath: configPath)' "$MANAGER" &&
grep -q 'try await commandService.startTunnel(configPath: configPath)' "$MANAGER" ||
    { echo "Wake reconnect must restart the tunnel interface via stop then start" >&2; exit 1; }
grep -q 'Lost connection after sleep' "$MANAGER" ||
    { echo "A tunnel that fails to reconnect after wake must surface an error, not a stale connected state" >&2; exit 1; }

echo "Sleep/wake reconnect checks passed"
