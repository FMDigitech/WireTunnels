import Foundation

@MainActor
final class WireGuardCommandService {
    func getRuntimeStatusSnapshot() async throws -> WireGuardStatusSnapshot {
        WireGuardStatusSnapshot(output: "", configPaths: [:])
    }
}

@main
struct SharedEndpointLifecycleTests {
    @MainActor static func main() async {
        let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
        let peerKey = Data(repeating: 2, count: 32).base64EncodedString()
        let localKey = WireGuardKey.publicKey(fromPrivateKey: privateKey)!
        let parser = WireGuardConfigParser()
        let config = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 192.168.89.2/32

        [Peer]
        PublicKey = \(peerKey)
        AllowedIPs = 192.168.88.0/24
        Endpoint = 192.0.2.10:13231
        """
        let split = parser.parse(string: config)
        guard split.isValid, split.allowedIPs == ["192.168.88.0/24"] else { fatalError("Split route parsing failed") }
        let candidates = ["split", "other"].map { name in
            InterfaceMatcher.Candidate(peerPublicKey: peerKey, localPublicKey: localKey, endpoint: "192.0.2.10:13231", interfaceHint: name, configName: name)
        }
        var snapshot = WireGuardStatusSnapshot(output: "", configPaths: [:])
        let monitor = StatusMonitorService(getWgShowOutput: { snapshot.output }, getRuntimeConfigPaths: { snapshot.configPaths })
        func dump(_ interface: String, _ routes: String, rx: Int, tx: Int) -> String {
            "\(interface)\t(hidden)\t\(localKey)\t1234\toff\n\(interface)\t\(peerKey)\t(none)\t192.0.2.10:13231\t\(routes)\t0\t\(rx)\t\(tx)\t25\n"
        }
        func assign(_ input: [InterfaceMatcher.Candidate]) async -> [Int: TunnelStatus] {
            guard await monitor.refresh() else { fatalError("Status refresh failed") }
            return InterfaceMatcher.assign(input, statuses: monitor.statusMap)
        }
        for otherRoute in ["0.0.0.0/24", "0.0.0.0/0"] {
            let other = parser.parse(string: config.replacingOccurrences(of: "192.168.88.0/24", with: otherRoute))
            guard other.isValid, other.allowedIPs == [otherRoute],
                  other.privateKey == split.privateKey, other.peerPublicKey == split.peerPublicKey,
                  other.endpoint == split.endpoint else { fatalError("Same-endpoint config parsing mixed up profile fields") }
            guard other.warnings.contains(.fullTunnel) == (otherRoute == "0.0.0.0/0") else { fatalError("/24 was treated as a full tunnel") }
            // Only the second profile is up, despite the first sharing all keys and the endpoint.
            snapshot = WireGuardStatusSnapshot(output: dump("utun7", otherRoute, rx: 200, tx: 40), configPaths: ["utun7": "/runtime/other.conf"])
            let onlyOther = await assign(candidates)
            guard onlyOther[0] == nil, onlyOther[1]?.peers.first?.allowedIPs == [otherRoute],
                  onlyOther[1]?.runtimeConfigPath == "/runtime/other.conf" else { fatalError("The split profile stole the other connection") }
            let reversed = await assign(Array(candidates.reversed()))
            guard reversed[0]?.runtimeConfigPath == "/runtime/other.conf", reversed[1] == nil else { fatalError("Matching depends on profile order") }
            // Switch to the first profile; utun7 is reused by the kernel.
            snapshot = WireGuardStatusSnapshot(output: dump("utun7", "192.168.88.0/24", rx: 10, tx: 5), configPaths: ["utun7": "/runtime/split.conf"])
            var staleHints = candidates
            staleHints[1].interfaceHint = "utun7"
            let onlySplit = await assign(staleHints)
            guard onlySplit[0]?.peers.first?.allowedIPs == ["192.168.88.0/24"], onlySplit[1] == nil else { fatalError("Switching profiles reused the old assignment") }
            // Both are up: routes, traffic counters and disconnect paths stay separate.
            snapshot = WireGuardStatusSnapshot(
                output: dump("utun7", "192.168.88.0/24", rx: 10, tx: 5) + dump("utun8", otherRoute, rx: 200, tx: 40),
                configPaths: ["utun7": "/runtime/split.conf", "utun8": "/runtime/other.conf"]
            )
            let both = await assign(staleHints)
            guard both[0]?.peers.first?.rxBytes == 10, both[0]?.peers.first?.txBytes == 5,
                  both[1]?.peers.first?.rxBytes == 200, both[1]?.peers.first?.txBytes == 40,
                  both[0]?.peers.first?.allowedIPs == ["192.168.88.0/24"], both[1]?.peers.first?.allowedIPs == [otherRoute],
                  both[0]?.runtimeConfigPath == "/runtime/split.conf", both[1]?.runtimeConfigPath == "/runtime/other.conf" else { fatalError("Both active profiles exchanged status or disconnect paths") }
            // A refresh after wake can report completely new utun numbers.
            staleHints[0].interfaceHint = "utun7"
            staleHints[1].interfaceHint = "utun8"
            snapshot = WireGuardStatusSnapshot(
                output: dump("utun10", "192.168.88.0/24", rx: 20, tx: 8) + dump("utun9", otherRoute, rx: 250, tx: 70),
                configPaths: ["utun10": "/runtime/split.conf", "utun9": "/runtime/other.conf"]
            )
            let reconnected = await assign(staleHints)
            guard reconnected[0]?.interfaceName == "utun10", reconnected[1]?.interfaceName == "utun9" else { fatalError("Wake reconnect mixed up profiles") }
            snapshot = WireGuardStatusSnapshot(output: "", configPaths: ["utun9": "/runtime/other.conf"])
            guard await assign(staleHints).isEmpty, monitor.activeInterfaces.isEmpty else { fatalError("Disconnected profiles remained active") }
        }
        // Endpoint equality alone never identifies a profile from another client.
        var differentClient = candidates[1]
        differentClient.localPublicKey = "another-client"
        snapshot = WireGuardStatusSnapshot(output: dump("utun7", "0.0.0.0/0", rx: 0, tx: 0), configPaths: ["utun7": "/runtime/other.conf"])
        guard await assign([differentClient]).isEmpty else { fatalError("Another client's profile matched the same endpoint") }
        print("PASS: shared-key/shared-endpoint profiles keep /24 and /0 routes, status, traffic, and disconnect paths separate")
    }
}
