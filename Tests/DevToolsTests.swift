import Foundation

@main
struct DevToolsTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() throws {
        expect(MagicPacket.parseMAC("AA:bb:0c:1D:2e:3F") == [0xAA, 0xBB, 0x0C, 0x1D, 0x2E, 0x3F], "a MAC with colons must parse")
        expect(MagicPacket.parseMAC("aa-bb-cc-dd-ee-ff") != nil, "a MAC with dashes must parse")
        for bad in ["", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "aabbccddeeff", "aa:bb:cc:dd:ee:gg", "a:bb:cc:dd:ee:ff", "+a:bb:cc:dd:ee:ff"] {
            expect(MagicPacket.parseMAC(bad) == nil, "\(bad) must be refused")
        }
        expect(MagicPacket.normalizedMAC("AA-BB-CC-DD-EE-FF") == "aa:bb:cc:dd:ee:ff", "MACs must be stored in one form")
        let packet = MagicPacket.packet(for: "01:02:03:04:05:06")!
        expect(packet.count == 102, "a magic packet is 102 bytes")
        expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6), "it starts with six 0xFF bytes")
        expect(packet.dropFirst(6).chunked(6).count == 16 && packet.dropFirst(6).chunked(6).allSatisfy { Array($0) == [1, 2, 3, 4, 5, 6] },
               "the MAC must repeat sixteen times")
        expect(MagicPacket.isIPv4("192.168.1.255") && !MagicPacket.isIPv4("host.local"), "the broadcast address must be a numeric IPv4")

        var tunnel = SSHTunnel(name: "db", host: "bastion.example.com", user: "deploy", port: 2222,
                               forwards: [SSHForward(listenPort: 5433, targetHost: "db.internal", targetPort: 5432)])
        let arguments = SSHTunnelCommand.arguments(for: tunnel)!
        expect(arguments.contains("127.0.0.1:5433:db.internal:5432"), "the forward must bind to loopback")
        expect(arguments.suffix(2) == ["--", "deploy@bastion.example.com"], "the destination must follow `--`")
        expect(arguments.contains("ExitOnForwardFailure=yes") && arguments.contains("BatchMode=yes"), "ssh must fail rather than prompt or half-work")
        expect(Array(arguments.prefix(2)) == ["-N", "-T"], "no remote command and no terminal")

        tunnel.host = "-oProxyCommand=evil"
        expect(SSHTunnelCommand.arguments(for: tunnel) == nil, "a host that looks like an option must be refused")
        tunnel.host = "bastion"
        tunnel.user = "-x"
        expect(SSHTunnelCommand.arguments(for: tunnel) == nil, "a user that looks like an option must be refused")
        tunnel.user = nil
        tunnel.forwards = []
        expect(SSHTunnelCommand.problem(with: tunnel) != nil, "a tunnel without forwards must be refused")
        tunnel.forwards = [SSHForward(listenPort: 80, targetHost: "a", targetPort: 80), SSHForward(listenPort: 80, targetHost: "b", targetPort: 81)]
        expect(SSHTunnelCommand.problem(with: tunnel) != nil, "a local port used twice must be refused")
        tunnel.forwards = [SSHForward(listenPort: 0, targetHost: "a", targetPort: 80)]
        expect(SSHTunnelCommand.problem(with: tunnel) != nil, "port 0 must be refused")
        tunnel.forwards = [SSHForward(listenPort: 8080, targetHost: "a b", targetPort: 80)]
        expect(SSHTunnelCommand.problem(with: tunnel) != nil, "a target host with a space must be refused")

        expect((0...8).map(SSHTunnelCommand.reconnectDelay) == [2, 4, 8, 16, 32, 60, 60, 60, 60], "the delay must double up to a minute")
        expect(SSHTunnelCommand.reconnectDelay(attempt: -3) == 2, "a negative attempt must act like the first")

        // Remote and SOCKS forwards.
        var mixed = SSHTunnel(name: "m", host: "h", forwards: [
            SSHForward(kind: .remote, listenPort: 9000, targetHost: "localhost", targetPort: 3000),
            SSHForward(kind: .dynamic, listenPort: 1080),
            SSHForward(listenPort: 9000, targetHost: "db", targetPort: 5432),
        ])
        let mixedArguments = SSHTunnelCommand.arguments(for: mixed)!
        expect(mixedArguments.contains("-R") && mixedArguments.contains("127.0.0.1:9000:localhost:3000"), "a remote forward must listen on the server's loopback")
        expect(mixedArguments.contains("-D") && mixedArguments.contains("127.0.0.1:1080"), "a SOCKS forward must listen on this Mac's loopback")
        expect(SSHTunnelCommand.problem(with: mixed) == nil, "a remote and a local forward may share a port number: they listen on different machines")
        mixed.forwards.append(SSHForward(kind: .dynamic, listenPort: 9000))
        expect(SSHTunnelCommand.problem(with: mixed) != nil, "a SOCKS and a local forward on the same local port must be refused")
        mixed.forwards = [SSHForward(kind: .remote, listenPort: 9000, targetHost: "-oProxy", targetPort: 1)]
        expect(SSHTunnelCommand.problem(with: mixed) != nil, "a remote forward's target host is checked too")

        expect(SSHForward.parse("8080:db:80") == SSHForward(listenPort: 8080, targetHost: "db", targetPort: 80), "a local line must parse")
        expect(SSHForward.parse("R:9000:localhost:3000") == SSHForward(kind: .remote, listenPort: 9000, targetHost: "localhost", targetPort: 3000), "a remote line must parse")
        expect(SSHForward.parse("D:1080") == SSHForward(kind: .dynamic, listenPort: 1080), "a SOCKS line must parse")
        for bad in ["", "D", "D:x", "D:1:2", "R:1:2", "1:2", "a:b:c", "X:1:h:2"] { expect(SSHForward.parse(bad) == nil, "\(bad) must not parse") }
        for forward in [SSHForward(listenPort: 1, targetHost: "h", targetPort: 2), SSHForward(kind: .remote, listenPort: 3, targetHost: "h", targetPort: 4), SSHForward(kind: .dynamic, listenPort: 5)] {
            expect(SSHForward.parse(forward.text) == forward, "\(forward.text) must survive being written and read")
        }
        let legacy = try JSONDecoder().decode(SSHForward.self, from: Data(#"{"localPort":5433,"remoteHost":"db","remotePort":5432}"#.utf8))
        expect(legacy == SSHForward(listenPort: 5433, targetHost: "db", targetPort: 5432), "a forward saved by the first version must still load")

        let decoded = try JSONDecoder().decode(SSHTunnel.self, from: JSONEncoder().encode(tunnel))
        expect(decoded == tunnel, "an SSH tunnel must survive a JSON round trip")
        print("PASS: Wake-on-LAN packets and SSH tunnel commands")
    }
}

private extension Data {
    func chunked(_ size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { self[index(startIndex, offsetBy: $0)..<index(startIndex, offsetBy: Swift.min($0 + size, count))] }
    }
}
