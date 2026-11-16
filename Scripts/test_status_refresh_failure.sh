#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsStatusRefreshTest.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/main.swift" <<'SWIFT'
import Foundation

@MainActor
final class WireGuardCommandService {
    func getRuntimeStatusSnapshot() async throws -> WireGuardStatusSnapshot {
        fatalError("The injected output provider should be used")
    }
}

enum TestError: Error {
    case refreshFailed
}

@main
struct StatusRefreshTest {
    @MainActor
    static func main() async {
        var nextResult: Result<String, Error> = .success(
            "wg0\tpublic-key\tprivate-key\t51820\toff"
        )
        let monitor = StatusMonitorService {
            try nextResult.get()
        }

        let initialRefreshSucceeded = await monitor.refresh()
        guard initialRefreshSucceeded else {
            fatalError("valid output should report a successful refresh")
        }
        guard monitor.activeInterfaces == ["wg0"],
              monitor.statusMap["wg0"]?.listenPort == 51820 else {
            fatalError("valid output did not establish the expected state")
        }

        let priorInterfaces = monitor.activeInterfaces
        let priorStatusMap = monitor.statusMap
        nextResult = .failure(TestError.refreshFailed)

        let failedRefreshSucceeded = await monitor.refresh()
        guard !failedRefreshSucceeded else {
            fatalError("a thrown status command should report refresh failure")
        }
        guard monitor.activeInterfaces == priorInterfaces,
              monitor.statusMap == priorStatusMap else {
            fatalError("a failed refresh must preserve the last known state")
        }

        nextResult = .success("")
        let emptyRefreshSucceeded = await monitor.refresh()
        guard emptyRefreshSucceeded else {
            fatalError("empty command output is still a successful refresh")
        }
        guard monitor.activeInterfaces.isEmpty, monitor.statusMap.isEmpty else {
            fatalError("successful empty output must clear status state")
        }

        print("Status refresh failure behavior passed")
    }
}
SWIFT

xcrun swiftc \
    -parse-as-library \
    "$ROOT_DIR/WireTunnels/Models/TunnelStatus.swift" \
    "$ROOT_DIR/WireTunnels/Services/StatusMonitorService.swift" \
    "$TEST_DIR/main.swift" \
    -o "$TEST_DIR/status-refresh-test"

"$TEST_DIR/status-refresh-test"
