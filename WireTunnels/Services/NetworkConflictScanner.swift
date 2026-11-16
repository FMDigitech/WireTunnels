import Combine
import Foundation
import Darwin

/// Reads the machine's routing table, DNS configuration, interfaces and process list.
/// Everything is unprivileged and local: no packet is sent, nothing is stored or uploaded.
nonisolated enum NetworkConflictScanner {
    /// Runs a system tool and returns its output. The output is drained before waiting so a big
    /// `scutil --dns` cannot fill the pipe and stall the tool. Blocking: call off the main actor.
    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    static func interfaces() -> [NetworkInterfaceInfo] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var byName: [String: [String]] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let name = current.pointee.ifa_name else { continue }
            let interface = String(cString: name)
            byName[interface, default: []] += []
            guard let address = current.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // A link-local IPv6 address prints with a "%utunN" scope.
            byName[interface, default: []].append(String(String(cString: host).prefix { $0 != "%" }))
        }
        return byName.map { NetworkInterfaceInfo(name: $0.key, addresses: $0.value.sorted()) }.sorted { $0.name < $1.name }
    }

    /// Blocking: call from a background task.
    static func snapshot(ownTunnels: [OwnTunnelState]) -> NetworkSnapshot {
        let routes = IPFamily.allCases.flatMap { family in
            NetstatRoutes.parse(run("/usr/sbin/netstat", ["-rn", "-f", family == .ipv4 ? "inet" : "inet6"]) ?? "", family: family)
        }
        return NetworkSnapshot(
            interfaces: interfaces(),
            routes: routes,
            resolvers: ScutilDNS.parse(run("/usr/sbin/scutil", ["--dns"]) ?? ""),
            products: KnownVPNProduct.detect(inProcessList: run("/bin/ps", ["-axo", "comm="]) ?? ""),
            ownTunnels: ownTunnels)
    }
}

/// Holds the latest scan for the Network Doctor screen. A scan is manual or on opening the screen;
/// nothing runs in the background.
@MainActor
final class NetworkDoctor: ObservableObject {
    @Published private(set) var findings: [NetworkFinding] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var scannedTunnelCount = 0

    private var queued: (tunnels: [Tunnel], killSwitchArmed: Set<UUID>)?

    func scan(tunnels: [Tunnel], killSwitchArmed: Set<UUID>) async {
        // A request that arrives mid-scan is kept, with the state it saw, and runs after this one.
        guard !isScanning else { queued = (tunnels, killSwitchArmed); return }
        isScanning = true
        defer { isScanning = false }
        var request = (tunnels: tunnels, killSwitchArmed: killSwitchArmed)
        while true {
            queued = nil
            await scanOnce(tunnels: request.tunnels, killSwitchArmed: request.killSwitchArmed)
            guard let next = queued else { break }
            request = next
        }
    }

    private func scanOnce(tunnels: [Tunnel], killSwitchArmed: Set<UUID>) async {
        let own = tunnels.filter(\.isActive).map { tunnel in
            OwnTunnelState(name: tunnel.name, interface: tunnel.interfaceName, allowedIPs: tunnel.allowedIPs,
                           dns: tunnel.dns, killSwitchArmed: killSwitchArmed.contains(tunnel.id),
                           addresses: (tunnel.address ?? []).map { String($0.prefix { $0 != "/" }).trimmingCharacters(in: .whitespaces) })
        }
        let result = await Task.detached {
            NetworkConflictAnalyzer.analyze(NetworkConflictScanner.snapshot(ownTunnels: own))
        }.value
        findings = result
        scannedTunnelCount = own.count
        lastScan = Date()
    }
}
