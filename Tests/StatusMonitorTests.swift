import Foundation

// The production monitor accepts a dump closure; this stub avoids launching XPC.
@MainActor
final class WireGuardCommandService {
    func getRuntimeStatusSnapshot() async throws -> WireGuardStatusSnapshot {
        WireGuardStatusSnapshot(output: "", configPaths: [:])
    }
}

@main
struct StatusMonitorTests {
    @MainActor static func main() async {
        var failMapping = false
        let monitor = StatusMonitorService(getWgShowOutput: {
            "utun7\t(hidden)\tclient\t1234\toff\nutun7\tserver\t(none)\t192.0.2.1:51820\t0.0.0.0/0\t0\t0\t0\toff\n"
        }, getRuntimeConfigPaths: {
            if failMapping { throw NSError(domain: "TestMapping", code: 1) }
            return ["utun7": "/runtime/full.conf", "utun8": "/runtime/stopped.conf"]
        })
        let refreshed = await monitor.refresh()
        let matched = InterfaceMatcher.assign([
            InterfaceMatcher.Candidate(peerPublicKey: "server", localPublicKey: "client", endpoint: "192.0.2.1:51820", interfaceHint: "full", configName: "full")
        ], statuses: monitor.statusMap)
        guard refreshed, matched[0]?.interfaceName == "utun7" else {
            print("FAIL: status refresh cannot associate the runtime config alias with utun7")
            exit(1)
        }
        guard monitor.statusMap["utun7"]?.runtimeConfigPath == "/runtime/full.conf",
              monitor.activeInterfaces == ["utun7"] else {
            print("FAIL: runtime path for disconnect was lost or an alias was counted twice")
            exit(1)
        }
        let previousMap = monitor.statusMap
        failMapping = true
        let failedRefresh = await monitor.refresh()
        guard !failedRefresh, monitor.statusMap == previousMap,
              monitor.activeInterfaces == ["utun7"], monitor.lastErrorDescription != nil else {
            print("FAIL: failed runtime discovery must preserve the last confirmed status")
            exit(1)
        }
        print("PASS: status refresh retains the actual runtime config for disconnect")
    }
}
