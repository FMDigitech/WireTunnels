import Foundation
import Combine

@MainActor
final class StatusMonitorService: ObservableObject {
    @Published var activeInterfaces: Set<String> = []
    @Published var statusMap: [String: TunnelStatus] = [:] // keyed by interface name
    private(set) var lastRawOutput = ""
    private(set) var lastErrorDescription: String?

    private let getSnapshot: @MainActor () async throws -> WireGuardStatusSnapshot

    init(commandService: WireGuardCommandService) {
        self.getSnapshot = { [weak commandService] in
            guard let commandService else {
                throw RefreshError.commandServiceUnavailable
            }
            return try await commandService.getRuntimeStatusSnapshot()
        }
    }

    init(
        getWgShowOutput: @escaping @MainActor () async throws -> String,
        getRuntimeConfigPaths: @escaping @MainActor () async throws -> [String: String] = { [:] }
    ) {
        self.getSnapshot = {
            let output = try await getWgShowOutput()
            let configPaths = try await getRuntimeConfigPaths()
            return WireGuardStatusSnapshot(output: output, configPaths: configPaths)
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        let output: String
        let configPaths: [String: String]
        do {
            let snapshot = try await getSnapshot()
            output = snapshot.output
            configPaths = snapshot.configPaths
        } catch {
            lastErrorDescription = error.localizedDescription
            return false
        }

        let parsed = parse(dumpOutput: output).map { status in
            var status = status
            status.runtimeConfigPath = configPaths[status.interfaceName]
            return status
        }
        lastErrorDescription = nil
        lastRawOutput = output
        statusMap = Dictionary(uniqueKeysWithValues: parsed.map { ($0.interfaceName, $0) })
        activeInterfaces = Set(parsed.map { $0.interfaceName })
        return true
    }

    private func parse(dumpOutput: String) -> [TunnelStatus] {
        var result: [TunnelStatus] = []
        var interfaceMap: [String: (pubKey: String, port: Int, peers: [PeerStatus])] = [:]

        for line in dumpOutput.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: "\t")
            if fields.count == 5 {
                // Interface line
                let iface = fields[0]
                let pubKey = fields[2]  // fields[1] is the private key
                let port = Int(fields[3]) ?? 0
                interfaceMap[iface] = (pubKey: pubKey, port: port, peers: [])
            } else if fields.count == 9 {
                // Peer line
                let iface = fields[0]
                let peerPubKey = fields[1]
                let endpoint = fields[3] == "(none)" ? nil : fields[3]
                let allowedIPs = fields[4].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let handshakeEpoch = Int64(fields[5]) ?? 0
                let lastHandshake: Date? = handshakeEpoch > 0 ? Date(timeIntervalSince1970: TimeInterval(handshakeEpoch)) : nil
                let rx = Int64(fields[6]) ?? 0
                let tx = Int64(fields[7]) ?? 0
                let keepalive = fields[8] == "off" ? nil : Int(fields[8])

                let peer = PeerStatus(
                    publicKey: peerPubKey,
                    endpoint: endpoint,
                    allowedIPs: allowedIPs,
                    lastHandshake: lastHandshake,
                    rxBytes: rx,
                    txBytes: tx,
                    persistentKeepalive: keepalive
                )
                interfaceMap[iface]?.peers.append(peer)
            }
        }

        for (iface, info) in interfaceMap {
            result.append(TunnelStatus(
                interfaceName: iface,
                publicKey: info.pubKey,
                listenPort: info.port,
                peers: info.peers
            ))
        }
        return result
    }

    private enum RefreshError: Error {
        case commandServiceUnavailable
    }
}
