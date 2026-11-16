#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wiretunnels-inventory-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find Shared WireTunnels/Models WireTunnels/Services -name '*.swift' ! -name UpdaterService.swift ! -name NotchController.swift | sort)
swiftc -module-cache-path "$test_dir/modules" "${sources[@]}" \
    WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift \
    WireTunnelsHelper/InventoryRouteSocket.swift WireTunnelsHelper/InventoryRoutingService.swift \
    WireTunnelsHelper/InventoryInterfaceMonitor.swift \
    Tests/InventoryAppFixture.swift Tests/InventoryRoutingTests.swift -o "$test_dir/tests"
"$test_dir/tests"
