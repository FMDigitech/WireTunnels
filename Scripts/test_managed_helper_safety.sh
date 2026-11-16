#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
MANAGER="${ROOT_DIR}/WireTunnels/Services/TunnelManager.swift"

grep -q 'validatedConfigName' "$HELPER"
grep -q 'validateConfigContents(contents)' "$HELPER"
grep -q 'writeManagedConfig' "$HELPER"
grep -q 'saveManagedRecords' "$HELPER"
grep -q 'AuthorizationCreateFromExternalForm' "$HELPER"
grep -q 'system.privilege.admin' "$HELPER"
grep -q 'posixPermissions: 0o600' "$HELPER"
grep -q 'posixPermissions: 0o644' "$HELPER"
grep -q 'managedConnectedUsersFile' "$HELPER"
grep -q 'listManagedTunnelUsers' "$HELPER"
! grep -q 'PrivateKey.*ManagedTunnelRecord' "$HELPER"
! grep -q 'PresharedKey.*ManagedTunnelRecord' "$HELPER"
grep -q 'effectiveHelperStatus' "$MANAGER"
grep -q 'SMAppService can lag behind launchd; a working XPC ping wins' "$MANAGER"

echo "Managed helper safety checks passed"
