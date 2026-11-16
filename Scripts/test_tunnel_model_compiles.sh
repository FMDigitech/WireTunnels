#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsModelTest.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" -typecheck \
    "${ROOT_DIR}/Shared/InventoryRouting.swift" \
    "${ROOT_DIR}/WireTunnels/Models/AutoConnectRule.swift" \
    "${ROOT_DIR}/WireTunnels/Models/Tunnel.swift"

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

let legacyJSON = """
{
  "id": "B4D9A9BE-A3DB-4E9E-84F0-546DFC7EF630",
  "name": "Legacy",
  "configPath": "/tmp/legacy.conf",
  "isActive": false,
  "isFavorite": false,
  "autostart": false,
  "allowedIPs": [],
  "dns": [],
  "rxBytes": 0,
  "txBytes": 0,
  "createdAt": "2026-06-12T12:00:00Z",
  "updatedAt": "2026-06-12T12:00:00Z"
}
"""

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let tunnel = try decoder.decode(Tunnel.self, from: Data(legacyJSON.utf8))

guard tunnel.autoConnectRule == AutoConnectRule() else {
    fatalError("Legacy tunnels must receive the default auto-connect rule")
}
guard tunnel.scope == .personal else {
    fatalError("Legacy tunnels must default to personal scope")
}
guard tunnel.managedPolicy == nil else {
    fatalError("Legacy personal tunnels must not receive managed policy")
}
guard tunnel.engine == .wireGuard else {
    fatalError("Tunnels saved before the engine field existed must run on WireGuard")
}

var managed = Tunnel(name: "Managed", configPath: "/Library/Application Support/WireTunnels/managed/configs/Managed.conf")
managed.scope = .managed
managed.managedPolicy = ManagedTunnelPolicy(usersCanConnect: true, usersCanDisconnect: false)
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let managedData = try encoder.encode(managed)
let decodedManaged = try decoder.decode(Tunnel.self, from: managedData)
guard decodedManaged.scope == .managed,
      decodedManaged.managedPolicy?.usersCanDisconnect == false else {
    fatalError("Managed tunnel scope and policy must round-trip")
}

// Rules saved by v1.0 had no "action" key at all: they could only connect.
let v10RuleJSON = """
{
  "enabled": true,
  "interface": "wifi",
  "wifiSSIDs": ["Office"]
}
"""

let v10Rule = try decoder.decode(AutoConnectRule.self, from: Data(v10RuleJSON.utf8))
guard v10Rule.connect.enabled, v10Rule.connect.wifiSSIDs == ["Office"], !v10Rule.disconnect.enabled else {
    fatalError("Rules saved before the action field existed must migrate to connect")
}

// Rules saved by 1.0.1 carried a single action per rule.
let flatDisconnectJSON = """
{
  "enabled": true,
  "interface": "wifi",
  "action": "disconnect",
  "wifiSSIDs": ["Cafe"]
}
"""
let flatDisconnect = try decoder.decode(AutoConnectRule.self, from: Data(flatDisconnectJSON.utf8))
guard flatDisconnect.disconnect.enabled, flatDisconnect.disconnect.wifiSSIDs == ["Cafe"],
      !flatDisconnect.connect.enabled else {
    fatalError("A flat disconnect rule must migrate to the disconnect half")
}

// Connect and disconnect halves are independent and round-trip in the current shape.
let splitRule = AutoConnectRule(
    connect: AutoConnectNetworkMatch(enabled: true, interface: .wifi, wifiSSIDs: ["Office"]),
    disconnect: AutoConnectNetworkMatch(enabled: true, interface: .wifi, wifiSSIDs: ["Cafe"])
)
let splitData = try encoder.encode(splitRule)
let decodedSplit = try decoder.decode(AutoConnectRule.self, from: splitData)
guard decodedSplit == splitRule, decodedSplit.enabled else {
    fatalError("Connect and disconnect halves must round-trip independently")
}
guard !AutoConnectRule().enabled else {
    fatalError("An empty rule must not be evaluated")
}

// The engine is part of tunnels.json, which the Windows app shares: raw values are a contract.
guard TunnelEngine.wireGuard.rawValue == "wireguard", TunnelEngine.amneziaWG.rawValue == "amneziawg" else {
    fatalError("Engine raw values must stay wireguard / amneziawg")
}
var amnezia = Tunnel(name: "Amnezia", configPath: "/tmp/amnezia.conf")
amnezia.engine = .amneziaWG
let amneziaData = try encoder.encode(amnezia)
let amneziaObject = try JSONSerialization.jsonObject(with: amneziaData) as! [String: Any]
guard amneziaObject["engine"] as? String == "amneziawg" else {
    fatalError("The engine must be written to tunnels.json as amneziawg")
}
guard try decoder.decode(Tunnel.self, from: amneziaData).engine == .amneziaWG else {
    fatalError("The AmneziaWG engine must round-trip")
}
guard Tunnel(name: "Plain", configPath: "/tmp/plain.conf").engine == .wireGuard else {
    fatalError("New tunnels must default to WireGuard")
}
// The user's choice of engine: optional in the file, never written when automatic.
let plainObject = try JSONSerialization.jsonObject(with: try encoder.encode(Tunnel(name: "Plain", configPath: "/tmp/plain.conf"))) as! [String: Any]
guard plainObject["enginePreference"] == nil else {
    fatalError("An automatic engine must not add a key to tunnels.json")
}
var chosen = Tunnel(name: "Chosen", configPath: "/tmp/chosen.conf")
chosen.enginePreference = .amneziaWG
let chosenData = try encoder.encode(chosen)
guard (try JSONSerialization.jsonObject(with: chosenData) as! [String: Any])["enginePreference"] as? String == "amneziawg",
      try decoder.decode(Tunnel.self, from: chosenData).enginePreference == .amneziaWG else {
    fatalError("The chosen engine must round-trip as enginePreference")
}
guard try decoder.decode(Tunnel.self, from: encoder.encode(Tunnel(name: "Old", configPath: "/tmp/old.conf"))).enginePreference == nil else {
    fatalError("A tunnel with no choice must stay automatic")
}
var unknownPreference = try JSONSerialization.jsonObject(with: chosenData) as! [String: Any]
unknownPreference["enginePreference"] = "somethingnew"
guard try decoder.decode(Tunnel.self, from: JSONSerialization.data(withJSONObject: unknownPreference)).enginePreference == nil else {
    fatalError("An engine this app does not know must load as automatic, not drop the tunnel")
}
guard TunnelEngine.resolve(preference: nil, usesAmneziaWG: false) == .wireGuard,
      TunnelEngine.resolve(preference: .amneziaWG, usesAmneziaWG: false) == .amneziaWG,
      TunnelEngine.resolve(preference: .wireGuard, usesAmneziaWG: false) == .wireGuard,
      TunnelEngine.resolve(preference: nil, usesAmneziaWG: true) == .amneziaWG,
      TunnelEngine.resolve(preference: .wireGuard, usesAmneziaWG: true) == .amneziaWG else {
    fatalError("AmneziaWG keys must always win; otherwise the choice decides")
}
guard TunnelEngine(usesAmneziaWG: true) == .amneziaWG, TunnelEngine(usesAmneziaWG: false) == .wireGuard else {
    fatalError("A config that uses AmneziaWG keys must map to the AmneziaWG engine")
}

// An engine this app does not know must not make the whole tunnel (and its file) unreadable.
var unknownObject = amneziaObject
unknownObject["engine"] = "someFutureEngine"
let unknownData = try JSONSerialization.data(withJSONObject: unknownObject)
guard try decoder.decode(Tunnel.self, from: unknownData).engine == .wireGuard else {
    fatalError("An unknown engine must fall back to WireGuard instead of failing to decode")
}
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/Shared/InventoryRouting.swift" \
    "${ROOT_DIR}/WireTunnels/Models/AutoConnectRule.swift" \
    "${ROOT_DIR}/WireTunnels/Models/Tunnel.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_tunnel_model"

"${TEST_DIR}/test_tunnel_model"
