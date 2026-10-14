import Foundation

@main
struct TunnelMatchingTests {
    static func main() {
        let peer = PeerStatus(publicKey: "server", endpoint: "192.0.2.1:51820", allowedIPs: ["0.0.0.0/0"], lastHandshake: nil, rxBytes: 0, txBytes: 0, persistentKeepalive: nil)
        let status = TunnelStatus(interfaceName: "utun7", publicKey: "client", listenPort: 1234, peers: [peer])
        let candidates = [
            InterfaceMatcher.Candidate(peerPublicKey: "server", localPublicKey: "client", endpoint: "192.0.2.1:51820", interfaceHint: "private"),
            InterfaceMatcher.Candidate(peerPublicKey: "server", localPublicKey: "client", endpoint: "192.0.2.1:51820", interfaceHint: "full")
        ]
        // wg-quick's runtime alias is authoritative even when profiles share keys.
        let matched = InterfaceMatcher.assign(candidates, statuses: ["utun7": status, "full": status])
        guard matched[1]?.interfaceName == "utun7", matched[0] == nil else {
            print("FAIL: first duplicate-key profile stole the full profile's interface")
            exit(1)
        }
        var boundStatus = status
        boundStatus.runtimeConfigPath = "/runtime/full.conf"
        var staleCandidates = candidates
        staleCandidates[0].interfaceHint = "utun7"
        staleCandidates[0].configName = "private"
        staleCandidates[1].configName = "full"
        let stale = InterfaceMatcher.assign(staleCandidates, statuses: ["utun7": boundStatus, "full": boundStatus])
        guard stale[1]?.interfaceName == "utun7", stale[0] == nil else {
            print("FAIL: a previously learned utun hint stole another profile's runtime alias")
            exit(1)
        }
        let privateStatus = TunnelStatus(interfaceName: "utun8", publicKey: "client", listenPort: 1235, peers: [peer], runtimeConfigPath: "/runtime/private.conf")
        let both = InterfaceMatcher.assign(staleCandidates, statuses: [
            "utun7": boundStatus, "full": boundStatus, "utun8": privateStatus, "private": privateStatus
        ])
        guard both[0]?.interfaceName == "utun8", both[1]?.interfaceName == "utun7" else {
            print("FAIL: duplicate-key profiles with two active aliases must remain independent")
            exit(1)
        }
        let orphan = TunnelStatus(interfaceName: "utun6", publicKey: "client", listenPort: 1234, peers: [peer], runtimeConfigPath: "/runtime/deleted-profile.conf")
        let recovered = InterfaceMatcher.assign([candidates[0]], statuses: ["utun6": orphan, "deleted-profile": orphan])
        guard recovered[0]?.runtimeConfigPath == "/runtime/deleted-profile.conf" else {
            print("FAIL: a recovered connection must keep its original runtime file for disconnect")
            exit(1)
        }
        var wrongClient = staleCandidates[1]
        wrongClient.localPublicKey = "other-client"
        guard InterfaceMatcher.assign([wrongClient], statuses: ["utun7": boundStatus, "full": boundStatus]).isEmpty else {
            print("FAIL: an alias must never bypass client key verification")
            exit(1)
        }
        let orphanKernelName = TunnelStatus(interfaceName: "utun7", publicKey: "client", listenPort: 1234, peers: [peer], runtimeConfigPath: "/runtime/old.conf")
        let kernelNamedConfig = TunnelStatus(interfaceName: "utun8", publicKey: "client", listenPort: 1235, peers: [peer], runtimeConfigPath: "/runtime/utun7.conf")
        let collisionCandidate = InterfaceMatcher.Candidate(peerPublicKey: "server", localPublicKey: "client", endpoint: "192.0.2.1:51820", interfaceHint: "utun7", configName: "utun7")
        let collision = InterfaceMatcher.assign([collisionCandidate], statuses: ["utun7": orphanKernelName, "utun8": kernelNamedConfig])
        guard collision[0]?.interfaceName == "utun8" else {
            print("FAIL: a config named utun7 must not match another tunnel's kernel utun7")
            exit(1)
        }
        print("PASS: runtime aliases take precedence over duplicate keys and stale hints")
    }
}
