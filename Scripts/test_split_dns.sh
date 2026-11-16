#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT_DIR}/WireTunnelsHelper/HelperTool.swift"
MANAGER="${ROOT_DIR}/WireTunnels/Services/TunnelManager.swift"
fail() { echo "split DNS test failed: $1" >&2; exit 1; }

for proto in "${ROOT_DIR}/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift" "${ROOT_DIR}/WireTunnelsHelper/WireguardHelperProtocol.swift"; do
    grep -q 'func syncSplitDNS(entries: Data, reply: @escaping (Bool, String?) -> Void)' "$proto" || fail "XPC protocol must expose syncSplitDNS"
done
grep -q 'func syncSplitDNS(entries: Data' "$HELPER" || fail "helper must implement syncSplitDNS"
grep -q 'resolverMarker' "$HELPER" || fail "helper must only touch resolver files it owns"
grep -q 'isValidResolverDomain' "$HELPER" || fail "helper must validate resolver domains"
grep -q 'isValidIPLiteral(server)' "$HELPER" || fail "helper must validate resolver servers"
grep -q 'effectiveSplitDNSDomains.isEmpty {' "$MANAGER" || fail "tunnels with split DNS must not set system-wide DNS"
grep -q 'await syncSplitDNSState()' "$MANAGER" || fail "resolver state must follow connect/disconnect"

grep -q 'strippingDNS' "$HELPER" || fail "shared tunnels with split DNS must be staged without DNS"
grep -q 'splitDNSDomains' "$HELPER" || fail "shared tunnel policy must carry split DNS domains"
grep -q 'uid \\(clientUser.uid)' "$HELPER" || fail "resolver ownership must be per user"
grep -q 'func updateManagedSplitDNSDomains' "$MANAGER" || fail "admins must be able to edit shared tunnel split DNS"
grep -q 'func splitDNSChangeNeedsReconnect' "$MANAGER" || fail "toggling split DNS on a live tunnel must offer a reconnect"

# Domain normalization is pure; compile just that function.
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsSplitDNS.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
{
  echo 'import Foundation'
  awk '/^nonisolated enum WireGuardDNS/,/^}$/' "${ROOT_DIR}/WireTunnels/Services/WireGuardConfigParser.swift"
  echo 'enum TunnelManager {'
  awk '/nonisolated static func normalizedSplitDNSDomain/,/^    }$/' "$MANAGER"
  echo '}'
  cat <<'SWIFT'
func check(_ input: String, _ expected: String?) {
    guard TunnelManager.normalizedSplitDNSDomain(input) == expected else {
        fatalError("normalize(\(input)) != \(String(describing: expected))")
    }
}
check("lan", "lan")
check(" *.Corp.Example. ", "corp.example")
check(".internal", "internal")
check("a b", nil)
check("../etc", nil)
check("bad..name", nil)
check("-x.lan", nil)
check("", nil)
print("Split DNS domain normalization passed")
SWIFT
} > "${TEST_DIR}/main.swift"
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/WireTunnelsModuleCache" "${TEST_DIR}/main.swift" -o "${TEST_DIR}/t"
"${TEST_DIR}/t"
echo "Split DNS checks passed"

# Resolver file handling, run against a temporary directory (no root needed).
{
  echo 'import Foundation'
  awk '/\/\/ BEGIN ResolverStore/,/\/\/ END ResolverStore/' "$HELPER" | sed 's/^private enum/enum/'
  cat <<'SWIFT'
func expect(_ c: Bool, _ m: String) { if !c { fatalError(m) } }
let fm = FileManager.default
let dir = NSTemporaryDirectory() + "resolver-\(UUID().uuidString)"
defer { try? fm.removeItem(atPath: dir) }
let me = "# Managed by WireTunnels (uid 501)"
let other = "# Managed by WireTunnels (uid 502)"

// foreign files and symlinks must survive and be reported
try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
try "nameserver 9.9.9.9\n".write(toFile: "\(dir)/corp.example", atomically: true, encoding: .utf8)
try fm.createSymbolicLink(atPath: "\(dir)/linked", withDestinationPath: "/etc/hosts")
try "nameserver 8.8.8.8\n".write(toFile: "\(dir)/keepme", atomically: true, encoding: .utf8)

var r = ResolverStore.sync(desired: ["lan": ["10.0.0.1", "10.0.0.2"], "corp.example": ["10.0.0.1"], "linked": ["10.0.0.1"]],
                           directory: dir, marker: me, fileManager: fm)
expect(r.failure == nil, "sync must not fail")
expect(r.conflicts.sorted() == ["corp.example", "linked"], "foreign domains must be conflicts: \(r.conflicts)")
expect(try String(contentsOfFile: "\(dir)/lan", encoding: .utf8) == "\(me)\nnameserver 10.0.0.1\nnameserver 10.0.0.2\n", "resolver content")
expect(try String(contentsOfFile: "\(dir)/corp.example", encoding: .utf8) == "nameserver 9.9.9.9\n", "foreign file untouched")
expect(fm.fileExists(atPath: "\(dir)/keepme"), "unrelated file untouched")
expect(((try fm.attributesOfItem(atPath: "\(dir)/lan"))[.posixPermissions] as? Int) == 0o644, "resolver permissions")

// another user's sync must not remove mine; mine removes only mine when no longer wanted
try "\(other)\nnameserver 1.1.1.1\n".write(toFile: "\(dir)/theirs", atomically: true, encoding: .utf8)
r = ResolverStore.sync(desired: [:], directory: dir, marker: me, fileManager: fm)
expect(!fm.fileExists(atPath: "\(dir)/lan"), "my stale resolver must be removed")
expect(fm.fileExists(atPath: "\(dir)/theirs"), "another user's resolver must stay")
expect(fm.fileExists(atPath: "\(dir)/corp.example") && fm.fileExists(atPath: "\(dir)/keepme"), "foreign files stay")
expect((try? fm.destinationOfSymbolicLink(atPath: "\(dir)/linked")) == "/etc/hosts", "symlink untouched")
print("Resolver store checks passed")
SWIFT
} > "${TEST_DIR}/resolver.swift"
mkdir -p "${TEST_DIR}/r" && cp "${TEST_DIR}/resolver.swift" "${TEST_DIR}/r/main.swift"
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/WireTunnelsModuleCache" "${TEST_DIR}/r/main.swift" -o "${TEST_DIR}/r/t"
"${TEST_DIR}/r/t"
