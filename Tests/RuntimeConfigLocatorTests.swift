import Foundation

@main
struct RuntimeConfigLocatorTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let paths = try RuntimeConfigLocator.configPaths(in: directory) { name in
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard paths["utun7"] == directory.appendingPathComponent("full.conf").path,
              paths.count == 1 else {
            print("FAIL: runtime mapping must resolve the original config and reject stale or invalid sockets")
            exit(1)
        }
        guard try RuntimeConfigLocator.hasUserspaceSockets(in: directory),
              try !RuntimeConfigLocator.hasUserspaceSockets(in: directory.appendingPathComponent("absent")) else {
            fatalError("Missing tools must not hide a surviving userspace socket")
        }
        let empty = directory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("utun13.sock"))
        guard try !RuntimeConfigLocator.hasUserspaceSockets(in: empty) else {
            fatalError("A regular file must not count as a userspace interface")
        }
        let missing = try RuntimeConfigLocator.configPaths(in: directory.appendingPathComponent("absent")) { _ in nil }
        guard missing.isEmpty else { exit(1) }

        // Engine choice comes from the config's own keys, in the section awg reads them from.
        func engine(_ text: String) -> RuntimeEngine { RuntimeEngine.engine(forConfig: text) }
        guard engine("[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = p\n") == .wireGuard,
              engine("[Interface]\nPrivateKey = k\njc = 5\n[Peer]\nPublicKey = p\n") == .amneziaWG,
              engine("[Interface]\nPrivateKey = k\n  H1 = 1-2\n") == .amneziaWG,
              engine("[Interface]\nPrivateKey = k\n[Peer]\nPublicKey = p\nAdvancedSecurity = on\n") == .amneziaWG,
              engine("[Interface]\nPrivateKey = k\n#Jc = 5\n") == .wireGuard,
              engine("[Peer]\nPublicKey = p\nJc = 5\n") == .wireGuard,
              engine("[Interface]\nPrivateKey = k\nAdvancedSecurity = on\n") == .wireGuard else {
            fatalError("The engine must follow the awg-only keys of the section they belong to")
        }
        // The engine the user chose reaches the helper as a marker comment in the staged copy.
        let plain = "[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = p\n"
        let marked = EngineMarker.addingAmneziaWGMarker(to: plain)
        guard engine(marked) == .amneziaWG, marked.hasPrefix(EngineMarker.amneziaWGLine + "\n"),
              EngineMarker.addingAmneziaWGMarker(to: marked) == marked,
              engine("# WireTunnels-Engine: amneziawg\n" + plain) == .amneziaWG,
              engine("  # wiretunnels-engine: amneziawg\n" + plain) == .amneziaWG,
              engine(plain + "# WireTunnels-Engine: amneziawg\n") == .amneziaWG,
              engine("# WireTunnels-Engine: wireguard\n" + plain) == .wireGuard,
              engine("# note WireTunnels-Engine: amneziawg\n" + plain) == .wireGuard,
              engine("[Interface]\nPrivateKey = k # WireTunnels-Engine: amneziawg\n") == .wireGuard,
              engine("# WireTunnels-Engine: amneziawg\n[Interface]\nPrivateKey = k\nJc = 5\n") == .amneziaWG else {
            fatalError("The engine marker must request AmneziaWG only as a whole comment line")
        }
        guard RuntimeEngine.amneziaWG.quickTool == "awg-quick", RuntimeEngine.amneziaWG.showTool == "awg",
              RuntimeEngine.amneziaWG.userspaceTool == "amneziawg-go",
              RuntimeEngine.amneziaWG.runtimeDirectory.path == "/var/run/amneziawg",
              RuntimeEngine.wireGuard.runtimeDirectory.path == "/var/run/wireguard" else {
            fatalError("Each engine must use its own tools and runtime directory")
        }
        guard RuntimeEngine.engine(runningAlias: "no-such-alias-\(UUID().uuidString)") == nil else {
            fatalError("An alias with no marker is not running")
        }

        // Dumps: the app must never receive a private key, a preshared key, the header
        // protection key or the obfuscation parameters.
        let wgDump = "wg0\tPRIVATE\tPUBLIC\t51820\toff\nwg0\tPEERKEY\tPRESHARED\t1.2.3.4:5\t0.0.0.0/0\t1\t2\t3\toff\n"
        let wgRedacted = RuntimeStatusDump.redactedWireGuard(wgDump)
        guard !wgRedacted.contains("PRIVATE"), !wgRedacted.contains("PRESHARED"), wgRedacted.contains("PUBLIC") else {
            fatalError("wg dump must hide the private and preshared keys")
        }
        let awgInterface = ["utun5", "PRIVATE", "PUBLIC", "51820", "5", "40", "70", "15", "18", "0", "0",
                            "1000-2000", "3000", "4000", "5000", "SIGNATURE1", "(null)", "(null)", "(null)", "(null)",
                            "HEADERKEY", "0", "0", "0", "0", "0", "0", "off", "off", "off"]
        precondition(awgInterface.count == 30)
        let awgPeer = ["utun5", "PEERKEY", "PRESHARED", "1.2.3.4:5", "0.0.0.0/0", "1", "2", "3", "off"]
        let awgDump = awgInterface.joined(separator: "\t") + "\n" + awgPeer.joined(separator: "\t") + "\n"
        let awgRedacted = RuntimeStatusDump.redactedAmnezia(awgDump)
        for secret in ["PRIVATE", "PRESHARED", "HEADERKEY", "SIGNATURE1", "1000-2000", "3000"] {
            guard !awgRedacted.contains(secret) else { fatalError("awg dump leaked \(secret)") }
        }
        let awgLines = awgRedacted.components(separatedBy: "\n")
        guard awgLines[0].components(separatedBy: "\t") == ["utun5", "(hidden)", "PUBLIC", "51820", "off"],
              awgLines[1].components(separatedBy: "\t").count == 9,
              awgLines[1].contains("PEERKEY"), awgLines[1].contains("1.2.3.4:5") else {
            fatalError("awg dump must reach the app in wg's 5- and 9-field shapes")
        }
        // Captured from the real awg (amneziawg-tools at the pinned revision) reading a UAPI
        // reply: `awg show all dump`, with synthetic keys. The interface line has 30 fields and
        // the peer line 9; if a new awg changes that, this is where it shows.
        let captured = "utun9\tASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8=\t6R55tN4Fl5KrLguINFCgTCPaPYENcnhPetAuZQIiKVI=\t51820\t5\t40\t70\t15\t18\t0\t0\t1000-2000\t3000\t4000\t5000-5500\t<b 0xc7000000><r 16>\t<t>\t\t\t\tESIzRFVmd4gRIjNEVWZ3iBEiM0RVZneIESIzRFVmd4g=\t10-20\t120\t5\t180\t10\t20\ton\toff\toff\nutun9\t/ty6mHZUMhD+3LqYdlQyEP7cuph2VDIQ/ty6mHZUMhA=\tqrvM3e7/ABGqu8zd7v8AEaq7zN3u/wARqrvM3e7/ABE=\t203.0.113.7:51820\t0.0.0.0/0,::/0\t1763060000\t5678\t1234\t25\n"
        precondition(captured.components(separatedBy: "\n")[0].components(separatedBy: "\t").count == 30,
                     "The captured awg interface line must have 30 fields")
        let capturedRedacted = RuntimeStatusDump.redactedAmnezia(captured)
        let capturedKeys = [
            "ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8=", // private key
            "qrvM3e7/ABGqu8zd7v8AEaq7zN3u/wARqrvM3e7/ABE=", // preshared key
            "ESIzRFVmd4gRIjNEVWZ3iBEiM0RVZneIESIzRFVmd4g=", // header protection key
            "<b 0xc7000000><r 16>", "1000-2000", "5000-5500"
        ]
        for secret in capturedKeys {
            precondition(captured.contains(secret), "Fixture lost a value it must prove is removed: \(secret)")
            guard !capturedRedacted.contains(secret) else { fatalError("Real awg output leaked \(secret)") }
        }
        let capturedLines = capturedRedacted.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard capturedLines.count == 2,
              capturedLines[0].components(separatedBy: "\t").count == 5,
              capturedLines[1].components(separatedBy: "\t").count == 9 else {
            fatalError("Real awg output must reach the app as one 5-field and one 9-field line")
        }
        // A signature value that itself contains tabs must not shift the interface fields.
        var tabbed = awgInterface
        tabbed[15] = "A\tB\tC"
        let tabbedRedacted = RuntimeStatusDump.redactedAmnezia(tabbed.joined(separator: "\t") + "\n")
        guard !tabbedRedacted.contains("PRIVATE"), !tabbedRedacted.contains("HEADERKEY"),
              tabbedRedacted.components(separatedBy: "\n")[0].components(separatedBy: "\t").count == 5 else {
            fatalError("Tabs inside a value must not leak or reshape the interface line")
        }
        // A shape this code does not know is dropped, not passed through.
        let unknown = RuntimeStatusDump.redactedAmnezia("utun5\tPRIVATE\tPUBLIC\n")
        guard !unknown.contains("PRIVATE"), !unknown.contains("PUBLIC") else {
            fatalError("An unrecognised awg line must be dropped")
        }
        print("PASS: runtime config discovery validates aliases and socket lifetimes")
    }
}
