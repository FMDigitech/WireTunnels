#!/bin/bash
set -euo pipefail

# The helper, not only the app, enforces shared-tunnel policy and tunnel ownership.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"

fail() {
    echo "helper access control test failed: $*" >&2
    exit 1
}

grep -q 'runtimeAccessDenial(for: configURL, action: .connect)' "$HELPER" ||
    fail "startTunnel must check the shared-tunnel policy and ownership"
grep -q 'runtimeAccessDenial(for: configURL, action: .disconnect)' "$HELPER" ||
    fail "stopTunnel must check the shared-tunnel policy and ownership"
grep -q 'throw HelperError.accessDenied("A shared tunnel already uses this name")' "$HELPER" ||
    fail "stageConfig must not replace a shared tunnel's runtime config"
grep -q 'throw HelperError.accessDenied("Another user'"'"'s tunnel already uses this name")' "$HELPER" ||
    fail "stageConfig must not replace another user's runtime config"
grep -q '.ownerAccountID: clientUser.uid' "$HELPER" ||
    fail "staged runtime configs must be owned by the staging user"
grep -q 'usersCanConnect ?? true), !callerIsAdministrator' "$HELPER" ||
    fail "stageManagedConfig must honour usersCanConnect"
grep -q 'mbr_check_membership' "$HELPER" ||
    fail "administrators must be recognised by admin group membership"

# Inventory apply changes routes and AllowedIPs on the named tunnel.
awk '/func updateInventoryRouting/,/inventoryService.perform\(request/' "$HELPER" |
    grep -q 'runtimeAccessDenial(for: config, action: .connect)' ||
    fail "inventory apply must check the named tunnel before changing its routes"
! awk '/private func inventoryInterface/,/^    }$/' "$HELPER" | grep -q 'runtimeAccessDenial' ||
    fail "inventoryInterface resolves every user's policy and must not check the current caller"

echo "Helper access control checks passed"
