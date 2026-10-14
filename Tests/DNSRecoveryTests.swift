import Darwin
import Foundation

private final class FakeDNSNetwork: DNSRecoveryNetwork {
    var values: [String: DNSSettings] = ["service-1": DNSSettings(dns: ["192.0.2.53"], search: ["original.example"])]
    var live: Set<String> = []
    var writeCount = 0
    var failField: DNSField?
    var afterWrite: (() -> Void)?
    var expireAfterFirstCheck = false
    var aliveChecks = 0
    func serviceID(named name: String) throws -> String { "service-1" }
    func serviceName(for id: String) throws -> String? { id == "service-1" ? "Wi-Fi" : nil }
    func isAlive(_ owner: DNSOwnerIdentity) -> Bool {
        aliveChecks += 1
        if expireAfterFirstCheck && aliveChecks > 1 { return false }
        return live.contains(owner.token + ":" + String(owner.inode))
    }
    func read(service: String, field: DNSField) throws -> [String] {
        field == .dns ? values["service-1"]!.dns : values["service-1"]!.search
    }
    func write(service: String, field: DNSField, values newValues: [String]) throws {
        if failField == field { throw NSError(domain: "fixture", code: 1) }
        writeCount += 1
        if field == .dns { values["service-1"]!.dns = newValues }
        else { values["service-1"]!.search = newValues }
        afterWrite?()
    }
}

private final class FileDNSNetwork: DNSRecoveryNetwork {
    let directory: URL
    let killAfterWrite: Bool
    init(directory: URL, killAfterWrite: Bool = false) { self.directory = directory; self.killAfterWrite = killAfterWrite }
    func serviceID(named name: String) throws -> String { "service-1" }
    func serviceName(for id: String) throws -> String? { "Wi-Fi" }
    func isAlive(_ owner: DNSOwnerIdentity) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("live").path) }
    func read(service: String, field: DNSField) throws -> [String] {
        let settings = try JSONDecoder().decode(DNSSettings.self, from: Data(contentsOf: directory.appendingPathComponent("network.json")))
        return field == .dns ? settings.dns : settings.search
    }
    func write(service: String, field: DNSField, values: [String]) throws {
        var settings = try JSONDecoder().decode(DNSSettings.self, from: Data(contentsOf: directory.appendingPathComponent("network.json")))
        if field == .dns { settings.dns = values } else { settings.search = values }
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("network.json"), options: .atomic)
        if killAfterWrite { _ = kill(getpid(), SIGKILL) }
    }
}

@main
struct DNSRecoveryTests {
    static func main() throws {
        if CommandLine.arguments.count == 4 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let network = FileDNSNetwork(directory: directory, killAfterWrite: true)
            let service = DNSRecoveryService(directory: directory.appendingPathComponent("journal"), network: network, expectedUID: getuid())
            if CommandLine.arguments[1] == "--crash-apply" {
                let owner = DNSOwnerIdentity(token: CommandLine.arguments[3], alias: "fixture", interface: "utun99", device: 1, inode: 1)
                try service.set(owner: owner, service: "Wi-Fi", settings: DNSSettings(dns: ["192.0.2.10"], search: ["a.example"]))
            } else { try service.recover() }
            preconditionFailure("Crash fixture did not reach a DNS setter")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dns-recovery-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = DNSSettings(dns: ["192.0.2.53"], search: ["original.example"])
        let aValues = DNSSettings(dns: ["192.0.2.10", "2001:db8::10"], search: ["a.example", "corp.example"])
        let bValues = DNSSettings(dns: ["192.0.2.20"], search: [])
        func fixture(_ label: String) -> (FakeDNSNetwork, DNSRecoveryService) {
            let network = FakeDNSNetwork()
            return (network, DNSRecoveryService(directory: root.appendingPathComponent(label), network: network, expectedUID: getuid()))
        }
        func owner(_ inode: UInt64 = 1) -> DNSOwnerIdentity {
            DNSOwnerIdentity(token: UUID().uuidString, alias: "fixture", interface: "utun99", device: 1, inode: inode)
        }
        func connect(_ network: FakeDNSNetwork, _ service: DNSRecoveryService, _ owner: DNSOwnerIdentity, _ values: DNSSettings) throws {
            network.live.insert(owner.token + ":" + String(owner.inode))
            try service.set(owner: owner, service: "Wi-Fi", settings: values)
        }
        // Removing persistence would lose the baseline in a fresh recovery instance.
        do {
            let (network, service) = fixture("fresh")
            let a = owner()
            try connect(network, service, a, aValues)
            network.live.removeAll()
            try DNSRecoveryService(directory: root.appendingPathComponent("fresh"), network: network, expectedUID: getuid()).recover()
            precondition(network.values["service-1"] == original, "Fresh recovery lost original DNS/search values")
        }
        // Independent tunnel snapshots would restore an already disconnected owner.
        for firstReleased in [true, false] {
            let (network, service) = fixture("overlap-" + String(firstReleased))
            let a = owner(), b = owner(2)
            try connect(network, service, a, aValues)
            try connect(network, service, b, bValues)
            try service.set(owner: a, service: "Wi-Fi", settings: aValues)
            precondition(network.values["service-1"] == bValues, "An older route monitor stole the newer owner's DNS")
            try service.release(token: firstReleased ? a.token : b.token)
            precondition(network.values["service-1"] == (firstReleased ? bValues : aValues), "Disconnect replaced a live owner's DNS")
            try service.release(token: firstReleased ? b.token : a.token)
            precondition(network.values["service-1"] == original, "Overlapping owners lost the shared original baseline")
        }
        // Route notifications must not rewrite unchanged DNS and create more route notifications.
        do {
            let (network, service) = fixture("repeated-monitor")
            let a = owner()
            try connect(network, service, a, aValues)
            let initialWrites = network.writeCount
            for _ in 0..<12 { try service.set(owner: a, service: "Wi-Fi", settings: aValues) }
            precondition(network.writeCount == initialWrites, "Monitor rewrote already-applied DNS")
        }
        // A reused utun number must not let the previous monitor claim the new socket.
        do {
            let (network, service) = fixture("recycled-interface")
            let a = owner(), b = owner(2)
            try connect(network, service, a, aValues)
            network.live.removeAll()
            try connect(network, service, b, bValues)
            do { try service.set(owner: a, service: "Wi-Fi", settings: aValues); preconditionFailure("Expected recycled interface rejection") } catch {}
            precondition(network.values["service-1"] == bValues, "Old monitor overwrote recycled interface DNS")
            try service.release(token: b.token)
            precondition(network.values["service-1"] == original, "Recycled interface lost original DNS")
        }
        // Interface death while waiting for the journal lock must be rechecked before setters.
        do {
            let (network, service) = fixture("expired-after-validation")
            let a = owner()
            network.live.insert(a.token + ":" + String(a.inode))
            network.expireAfterFirstCheck = true
            do { try service.set(owner: a, service: "Wi-Fi", settings: aValues); preconditionFailure("Expected locked interface revalidation") } catch {}
            precondition(network.values["service-1"] == original, "Delayed ownership claim changed DNS after its interface disappeared")
        }
        // Setter failure after one restored field must preserve the other field for retry.
        do {
            let (network, service) = fixture("partial")
            let a = owner()
            try connect(network, service, a, aValues)
            network.failField = .search
            do { try service.release(token: a.token); preconditionFailure("Expected restoration failure") } catch {}
            precondition(network.values["service-1"]!.dns == original.dns, "Successful DNS restoration was discarded")
            network.failField = nil
            try service.recover()
            precondition(network.values["service-1"] == original, "Failed search restoration could not be retried")
        }
        // A write that succeeds before interruption must be recognized from pending intent.
        do {
            let (network, service) = fixture("interrupted-write")
            let a = owner()
            network.live.insert(a.token + ":" + String(a.inode))
            network.afterWrite = { network.afterWrite = nil; network.failField = .search }
            do { try service.set(owner: a, service: "Wi-Fi", settings: aValues); preconditionFailure("Expected interruption") } catch {}
            network.failField = nil
            network.live.removeAll()
            try service.recover()
            precondition(network.values["service-1"] == original, "Partial startup did not recover")
        }
        // Manual DNS changes should survive cleanup while untouched search domains restore.
        do {
            let (network, service) = fixture("manual")
            let a = owner()
            try connect(network, service, a, aValues)
            network.values["service-1"]!.dns = ["203.0.113.53"]
            try service.release(token: a.token)
            precondition(network.values["service-1"] == DNSSettings(dns: ["203.0.113.53"], search: original.search), "Cleanup overwrote manual DNS")
        }
        // Repeated monitor callbacks must not reactivate a released generation.
        do {
            let (network, service) = fixture("stale-monitor")
            let a = owner()
            try connect(network, service, a, aValues)
            try service.release(token: a.token)
            try service.set(owner: a, service: "Wi-Fi", settings: aValues)
            precondition(network.values["service-1"] == original, "A stale monitor recreated a released DNS owner")
            network.live.removeAll()
            do { try service.set(owner: a, service: "Wi-Fi", settings: aValues); preconditionFailure("Expected stale interface rejection") } catch {}
            precondition(network.values["service-1"] == original, "Recycled interface inherited stale DNS")
        }
        // Returning DNS to the baseline manually must not be mistaken for managed ownership.
        do {
            let (network, service) = fixture("manual-baseline")
            let a = owner()
            try connect(network, service, a, aValues)
            network.values["service-1"]!.dns = original.dns
            try service.recover()
            precondition(network.values["service-1"]!.dns == original.dns, "Recovery overwrote a manual return to baseline")
        }
        // Real process death after the setter exercises the write-ahead journal and OS lock release.
        for restoring in [false, true] {
            let directory = root.appendingPathComponent("sigkill-" + String(restoring))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let network = FileDNSNetwork(directory: directory)
            try JSONEncoder().encode(original).write(to: directory.appendingPathComponent("network.json"))
            try Data().write(to: directory.appendingPathComponent("live"))
            let a = owner()
            let service = DNSRecoveryService(directory: directory.appendingPathComponent("journal"), network: network, expectedUID: getuid())
            if restoring {
                try service.set(owner: a, service: "Wi-Fi", settings: aValues)
                try FileManager.default.removeItem(at: directory.appendingPathComponent("live"))
            }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [restoring ? "--crash-recover" : "--crash-apply", directory.path, a.token]
            try child.run()
            child.waitUntilExit()
            precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "Fixture did not force termination")
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("live"))
            try service.recover()
            let actual = try JSONDecoder().decode(DNSSettings.self, from: Data(contentsOf: directory.appendingPathComponent("network.json")))
            precondition(actual == original, "SIGKILL lost the recoverable original DNS state")
        }
        // SIGKILL can leave the socket inode and alias behind after the listener dies.
        do {
            let runtime = URL(fileURLWithPath: "/tmp/wiretunnels-dns-uapi-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: runtime) }
            let path = runtime.appendingPathComponent("utun99.sock").path
            let marker = runtime.appendingPathComponent("fixture.name")
            try Data("utun99\n".utf8).write(to: marker)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(path.utf8) + [UInt8(0)]
            precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { target in
                    for index in bytes.indices { target[index] = bytes[index] }
                }
            }
            let server = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(server >= 0)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            precondition(bound == 0, "Unable to bind local UAPI fixture: " + String(errno))
            precondition(listen(server, 8) == 0, "Unable to listen on local UAPI fixture: " + String(errno))
            var attributes = stat()
            precondition(lstat(path, &attributes) == 0)
            let a = DNSOwnerIdentity(token: UUID().uuidString, alias: "fixture", interface: "utun99", device: UInt64(UInt32(bitPattern: attributes.st_dev)), inode: UInt64(attributes.st_ino))
            let network = SystemDNSRecoveryNetwork(runtimeDirectory: runtime, expectedUID: getuid())
            precondition(network.isAlive(a), "Listening UAPI fixture was rejected")
            close(server)
            precondition(FileManager.default.fileExists(atPath: path), "Fixture unexpectedly removed stale socket pathname")
            let started = ProcessInfo.processInfo.systemUptime
            precondition(!network.isAlive(a), "Dead UAPI listener retained DNS ownership because socket files survived")
            precondition(ProcessInfo.processInfo.systemUptime - started < 0.5, "UAPI liveness probe exceeded its deadline")
        }
        // Journal symlinks cannot cause privileged reads or writes outside the state directory.
        do {
            let (network, service) = fixture("symlink")
            let directory = root.appendingPathComponent("symlink")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let target = root.appendingPathComponent("unrelated")
            try Data("unchanged".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("state.json"), withDestinationURL: target)
            do { try service.recover(); preconditionFailure("Expected journal symlink rejection") } catch {}
            let unchanged = try String(contentsOf: target, encoding: .utf8)
            precondition(unchanged == "unchanged", "Journal symlink modified another file")
            _ = network
        }
        print("PASS: persistent DNS recovery preserves baselines, live owners, retries and manual settings")
    }
}
