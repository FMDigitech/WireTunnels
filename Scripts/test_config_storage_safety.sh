#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsStorageSafety.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("WireTunnelsStorage-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }

let storage = ConfigStorageService(configDirectory: root)

let allowedFileNameScalars = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-"
)
let spacedName = ConfigStorageService.fileBaseName(for: "Office VPN")
guard spacedName != "Office VPN",
      spacedName.unicodeScalars.allSatisfy({ allowedFileNameScalars.contains($0) }),
      spacedName.utf8.count <= ConfigStorageService.maxInterfaceNameLength,
      ConfigStorageService.fileBaseName(for: "Office VPN") == spacedName else {
    fatalError("spaces must be converted to a safe, deterministic file name")
}
let traversalName = ConfigStorageService.fileBaseName(for: "../../escape")
guard !traversalName.contains("/"), !traversalName.contains(".."),
      traversalName.utf8.count <= ConfigStorageService.maxInterfaceNameLength else {
    fatalError("path separators and traversal markers must be sanitized")
}

do {
    _ = try storage.saveConfig(name: "", content: "test")
    fatalError("empty names must be rejected")
} catch ConfigStorageError.invalidName {
}

let longName = "office_site_desktop"
let longURL = try storage.saveConfig(name: longName, content: "long")
let longBase = longURL.deletingPathExtension().lastPathComponent
guard longBase.utf8.count <= 15, longBase != longName else {
    fatalError("display names longer than 15 characters must map to a short wg-quick file name")
}
guard ConfigStorageService.fileBaseName(for: longName) == longBase,
      ConfigStorageService.fileBaseName(for: "office_site_laptop") != longBase else {
    fatalError("short file names must be deterministic and distinct per display name")
}
guard ConfigStorageService.fileBaseName(for: "Office") == "Office" else {
    fatalError("names that already fit must be unchanged")
}

let first = try storage.saveConfig(name: "Office", content: "first")
guard first.lastPathComponent == "Office.conf" else {
    fatalError("valid names must map to a config file")
}

do {
    _ = try storage.saveConfig(name: "Office", content: "second")
    fatalError("duplicate names must not overwrite existing configs")
} catch ConfigStorageError.alreadyExists {
}

let contents = try String(contentsOf: first, encoding: .utf8)
guard contents == "first" else {
    fatalError("duplicate saves must preserve the existing config")
}

print("Config storage safety checks passed")
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnels/Services/AppPaths.swift" \
    "${ROOT_DIR}/WireTunnels/Services/ConfigStorageService.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_config_storage_safety"

"${TEST_DIR}/test_config_storage_safety"
