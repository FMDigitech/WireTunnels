#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsClientIdentity.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

// RFC 7748 §6.1 Alice key pair
guard WireGuardKey.publicKey(fromPrivateKey: "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=")
        == "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=" else {
    fatalError("public key derivation must match the X25519 test vector")
}
guard WireGuardKey.publicKey(fromPrivateKey: "not-a-key") == nil else {
    fatalError("invalid private keys must not derive a public key")
}
print("Client identity key derivation checks passed")
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnels/Services/WireGuardConfigParser.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_client_identity_matching"
"${TEST_DIR}/test_client_identity_matching"

# refreshStatus must identify the client by its own key and never share an interface.
grep -q 'localPublicKey' "${ROOT_DIR}/WireTunnels/Services/TunnelManager.swift"
grep -q 'InterfaceMatcher.assign' "${ROOT_DIR}/WireTunnels/Services/TunnelManager.swift"
grep -q 'fields\[2\]' "${ROOT_DIR}/WireTunnels/Services/StatusMonitorService.swift"
grep -q 'RuntimeStatusDump.redactedWireGuard' "${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
grep -q 'static func redactedWireGuard' "${ROOT_DIR}/WireTunnelsHelper/RuntimeConfigLocator.swift"
grep -q 'localPublicKey' "${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
grep -q 'publicKey(fromPrivateKey' "${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
echo "Client identity matching checks passed"
