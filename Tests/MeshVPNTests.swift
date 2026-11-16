import Foundation

@main
struct MeshVPNTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    // Written from the documented shape of `tailscale status --json`, not captured from a client.
    static let running = """
    {
      "Version": "1.80.0",
      "BackendState": "Running",
      "TailscaleIPs": ["100.64.0.10", "fd7a:115c:a1e0::a"],
      "Self": {"HostName": "my-mac", "DNSName": "my-mac.example.ts.net.", "TailscaleIPs": ["100.64.0.10", "fd7a:115c:a1e0::a"],
               "Online": true, "ExitNode": false, "ExitNodeOption": false},
      "Health": ["Tailscale can't reach the configured DNS servers."],
      "CurrentTailnet": {"Name": "me@example.com", "MagicDNSSuffix": "example.ts.net", "MagicDNSEnabled": true},
      "Peer": {
        "nodekey:aaa": {"HostName": "berlin", "DNSName": "berlin.example.ts.net.", "TailscaleIPs": ["100.64.0.2/32", "fd7a:115c:a1e0::2"],
                        "Online": true, "ExitNode": true, "ExitNodeOption": true, "CurAddr": "203.0.113.5:41641"},
        "nodekey:bbb": {"HostName": "Amsterdam", "TailscaleIPs": ["100.64.0.3"], "Online": false, "ExitNode": false, "ExitNodeOption": true},
        "nodekey:ccc": {"HostName": "printer", "TailscaleIPs": ["100.64.0.4"], "Online": true, "ExitNode": false, "ExitNodeOption": false, "Relay": "fra"}
      }
    }
    """

    static func main() {
        let status = MeshVPNParser.parse(Data(running.utf8), kind: .tailscale)
        check(status != nil, "a Tailscale status is read")
        guard let status else { return }
        check(status.state == .running && status.state.canToggle, "running state")
        check(status.deviceName == "my-mac", "device name")
        check(status.addresses == ["100.64.0.10", "fd7a:115c:a1e0::a"], "own addresses")
        check(status.networkName == "example.ts.net", "network name")
        check(status.peersTotal == 3 && status.peersOnline == 2, "peer counts: \(String(describing: status.peersOnline))/\(String(describing: status.peersTotal))")
        check(status.health == ["Tailscale can't reach the configured DNS servers."], "health messages")
        let paths = Dictionary(uniqueKeysWithValues: status.peers.map { ($0.name, $0.path) })
        check(status.peers.count == 3 && paths["berlin"] == .direct && paths["printer"] == .relay && paths["Amsterdam"] == .some(nil),
              "peer paths follow the client: a current address is direct, a relay only is relayed, offline has none")
        check(status.exitNodes.map(\.name) == ["Amsterdam", "berlin"], "exit nodes are the peers that offer it, sorted without case")
        check(status.exitNodes.map(\.id) == ["100.64.0.3", "100.64.0.2"], "an exit node is addressed by its IPv4 address without a prefix length")
        check(status.activeExitNode?.name == "berlin", "the exit node in use")
        check(status.exitNodes.first { $0.name == "Amsterdam" }?.online == false, "an offline exit node is marked")

        // Other backend states.
        func state(_ name: String) -> MeshVPNState? {
            MeshVPNParser.parse(Data("{\"BackendState\": \"\(name)\"}".utf8), kind: .tailscale)?.state
        }
        check(state("Stopped") == .stopped && state("Stopped")!.canToggle, "stopped can be turned on")
        check(state("NeedsLogin") == .needsLogin && !state("NeedsLogin")!.canToggle, "a login cannot be done from here")
        check(state("NeedsMachineAuth") == .needsApproval && !state("NeedsMachineAuth")!.canToggle, "an approval cannot be done from here")
        check(state("Starting") == .starting, "starting")
        check(state("SomethingNew") == .unknown("SomethingNew") && !state("SomethingNew")!.canToggle, "an unknown state is shown, not acted on")

        // A stopped client has no peers and may omit most fields.
        let bare = MeshVPNParser.parse(Data("{\"BackendState\": \"Stopped\"}".utf8), kind: .tailscale)
        check(bare?.exitNodes.isEmpty == true && bare?.peersTotal == nil && bare?.deviceName == nil, "missing fields stay blank")
        // A field of the wrong type must not throw the whole status away silently as a wrong value.
        check(MeshVPNParser.parse(Data("not json".utf8), kind: .tailscale) == nil, "garbage is not a status")
        check(MeshVPNParser.parse(Data("[]".utf8), kind: .tailscale) == nil, "an array is not a status")
        check(MeshVPNParser.parse(Data(), kind: .netbird) == nil, "empty output is not a status")

        // An exit-node peer with no usable address is left out rather than listed unselectable.
        let noAddress = MeshVPNParser.parse(Data("""
        {"BackendState": "Running", "Peer": {"k": {"HostName": "x", "TailscaleIPs": ["not-an-ip"], "ExitNodeOption": true}}}
        """.utf8), kind: .tailscale)
        check(noAddress?.exitNodes.isEmpty == true, "an exit node without a valid address is not offered")
        let v6First = MeshVPNParser.parse(Data("""
        {"BackendState": "Running", "Peer": {"k": {"HostName": "x", "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.64.0.2"], "ExitNodeOption": true}}}
        """.utf8), kind: .tailscale)
        check(v6First?.exitNodes.first?.id == "100.64.0.2", "the IPv4 address is preferred even when listed second")
        let v6Only = MeshVPNParser.parse(Data("""
        {"BackendState": "Running", "Peer": {"k": {"HostName": "x", "TailscaleIPs": ["fd7a:115c:a1e0::2"], "ExitNodeOption": true}}}
        """.utf8), kind: .tailscale)
        check(v6Only?.exitNodes.first?.id == "fd7a:115c:a1e0::2", "an IPv6-only exit node uses its IPv6 address")

        // NetBird, from the documented shape of `netbird status --json`.
        let netbird = MeshVPNParser.parse(Data("""
        {"management": {"url": "https://api.netbird.io:443", "connected": true}, "netbirdIp": "100.92.1.5/16",
         "fqdn": "my-mac.netbird.cloud", "peers": {"total": 4, "connected": 3, "details": []}}
        """.utf8), kind: .netbird)
        check(netbird?.state == .running && netbird?.deviceName == "my-mac.netbird.cloud", "netbird state and name")
        check(netbird?.addresses == ["100.92.1.5"] && netbird?.peersOnline == 3 && netbird?.peersTotal == 4, "netbird address and peers")
        check(netbird?.exitNodes.isEmpty == true && MeshVPNKind.netbird.supportsExitNodes == false, "exit nodes are Tailscale only")
        let down = MeshVPNParser.parse(Data("{\"management\": {\"connected\": false}}".utf8), kind: .netbird)
        check(down?.state == .stopped, "netbird disconnected is off")
        let silent = MeshVPNParser.parse(Data("{}".utf8), kind: .netbird)
        check(silent?.state == .unknown(""), "netbird without a management block is unknown, not off")

        // Commands: only an IP literal reaches the command line.
        check(MeshVPNCommand.setExitNode("100.64.0.2") == ["set", "--exit-node=100.64.0.2"], "set an exit node")
        check(MeshVPNCommand.setExitNode(nil) == ["set", "--exit-node="], "clear the exit node")
        check(MeshVPNCommand.setExitNode("fd7a:115c:a1e0::2") == ["set", "--exit-node=fd7a:115c:a1e0::2"], "an IPv6 exit node")
        check(MeshVPNCommand.setExitNode("berlin") == nil, "a name is not accepted")
        check(MeshVPNCommand.setExitNode("100.64.0.2 --accept-routes") == nil, "extra options cannot ride along")
        check(MeshVPNCommand.setExitNode("") == nil, "an empty address is not accepted")
        check(MeshVPNKind.tailscale.upArguments == ["up"] && MeshVPNKind.netbird.downArguments == ["down"], "on and off")
        check(MeshVPNKind.allCases.allSatisfy { !$0.candidatePaths.isEmpty }, "every client has places to look")
        print("PASS: mesh vpn status and commands")
    }
}
