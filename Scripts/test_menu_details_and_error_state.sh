#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAVIGATION="$ROOT_DIR/WireTunnels/Services/DashboardNavigation.swift"
APP="$ROOT_DIR/WireTunnels/WireTunnelsApp.swift"
MENU="$ROOT_DIR/WireTunnels/Views/MenuBar/MenuBarView.swift"
DASHBOARD="$ROOT_DIR/WireTunnels/Views/Dashboard/MainDashboardView.swift"

test -f "$NAVIGATION" ||
    { echo "DashboardNavigation service is missing" >&2; exit 1; }

grep -q 'final class DashboardNavigation: ObservableObject' "$NAVIGATION" ||
    { echo "DashboardNavigation must be a shared ObservableObject" >&2; exit 1; }
grep -Eq '@Published( private\(set\))? var requestedTunnelID: UUID\?' "$NAVIGATION" ||
    { echo "DashboardNavigation must publish a tunnel UUID request" >&2; exit 1; }
grep -q 'func requestTunnel(_ tunnelID: UUID)' "$NAVIGATION" ||
    { echo "DashboardNavigation must accept tunnel detail requests" >&2; exit 1; }
grep -q 'func consumeRequest' "$NAVIGATION" ||
    { echo "DashboardNavigation requests must be consumable" >&2; exit 1; }

grep -q '@StateObject private var dashboardNavigation: DashboardNavigation' "$APP" ||
    { echo "The app must own one DashboardNavigation instance" >&2; exit 1; }
test "$(grep -c '\.environmentObject(dashboardNavigation)' "$APP")" -ge 2 ||
    { echo "Menu and dashboard scenes must share DashboardNavigation" >&2; exit 1; }

grep -q '@EnvironmentObject var dashboardNavigation: DashboardNavigation' "$MENU" ||
    { echo "The menu must receive DashboardNavigation" >&2; exit 1; }
test "$(grep -c 'Label("Open Details"' "$MENU")" -ge 2 ||
    { echo "Both menu tunnel row styles must expose Open Details" >&2; exit 1; }
grep -q 'dashboardNavigation.requestTunnel(tunnelID)' "$MENU" ||
    { echo "Open Details must request the selected tunnel UUID" >&2; exit 1; }
grep -q 'openWindow(id: "dashboard")' "$MENU" ||
    { echo "Open Details must open the singleton dashboard" >&2; exit 1; }

grep -q '@EnvironmentObject var dashboardNavigation: DashboardNavigation' "$DASHBOARD" ||
    { echo "The dashboard must receive DashboardNavigation" >&2; exit 1; }
grep -q 'onReceive(dashboardNavigation\.$requestedTunnelID.compactMap' "$DASHBOARD" ||
    { echo "The dashboard must consume published tunnel requests" >&2; exit 1; }
grep -q 'selection = .all' "$DASHBOARD" ||
    { echo "A detail request must select All Tunnels" >&2; exit 1; }
grep -q 'tunnelManager.tunnels.first { $0.id == tunnelID }' "$DASHBOARD" ||
    { echo "A detail request must select the matching tunnel" >&2; exit 1; }
grep -q 'dashboardNavigation.consumeRequest' "$DASHBOARD" ||
    { echo "The dashboard must clear handled requests" >&2; exit 1; }

grep -q 'hasError: tunnelManager.errorMessage != nil' "$APP" ||
    { echo "The menu icon must use TunnelManager.errorMessage" >&2; exit 1; }
grep -q 'if hasError { return .systemRed }' "$APP" ||
    { echo "Error state must render red with highest precedence" >&2; exit 1; }
grep -q 'if hasWarnings { return .systemYellow }' "$APP" ||
    { echo "Warning state must render yellow after errors" >&2; exit 1; }
grep -q 'if hasActive { return .systemGreen }' "$APP" ||
    { echo "Active state must render green after errors and warnings" >&2; exit 1; }

echo "Menu details and error icon checks passed"
