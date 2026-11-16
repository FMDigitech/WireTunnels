#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASHBOARD="$ROOT_DIR/WireTunnels/Views/Dashboard/MainDashboardView.swift"

grep -q 'var usesTunnelDetail: Bool' "$DASHBOARD" ||
    { echo "Sidebar sections must classify tunnel-detail usage" >&2; exit 1; }
grep -q 'case \.all, \.active, \.shared, \.favorites:' "$DASHBOARD" ||
    { echo "Tunnel sections must retain the detail column" >&2; exit 1; }
grep -q 'case \.multiHop, \.profiles, \.doctor, \.mesh, \.devTools, \.warnings, \.settings, \.log:' "$DASHBOARD" ||
    { echo "Global sections must omit the detail column" >&2; exit 1; }
test "$(grep -c 'NavigationSplitView {' "$DASHBOARD")" -eq 1 ||
    { echo "Dashboard must keep one persistent navigation split view" >&2; exit 1; }
grep -q 'private var tunnelWorkspace: some View' "$DASHBOARD" ||
    { echo "Tunnel workspace must remain alive across section changes" >&2; exit 1; }
grep -q 'HSplitView {' "$DASHBOARD" ||
    { echo "Tunnel list and detail must use a persistent resizable split" >&2; exit 1; }
grep -q '@State private var tunnelFilter: SidebarItem = \.all' "$DASHBOARD" ||
    { echo "The last tunnel filter must survive global section changes" >&2; exit 1; }
grep -q '\.opacity(selection\.usesTunnelDetail ? 1 : 0)' "$DASHBOARD" ||
    { echo "Global sections must hide, not destroy, the tunnel workspace" >&2; exit 1; }

echo "Adaptive dashboard layout checks passed"
