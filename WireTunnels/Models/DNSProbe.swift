import Foundation

/// A minimal DNS query and response check, used to measure a resolver's latency and to find out
/// whether the DNS servers a profile picked actually answer.
enum DNSProbe {
    /// A standard recursive query for the A record of `name`. The id lets the reply be matched.
    static func query(name: String, id: UInt16) -> Data? {
        var data = Data([UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63, label.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return data
    }

    /// True when `response` answers the query with this id: the same id, the response bit set and no
    /// error other than "name does not exist". Any reply proves the server works, even NXDOMAIN.
    static func isAnswer(_ response: Data, id: UInt16) -> Bool {
        guard response.count >= 12 else { return false }
        let bytes = [UInt8](response.prefix(4))
        guard UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id, bytes[2] & 0x80 != 0 else { return false }
        let code = bytes[3] & 0x0F
        return code == 0 || code == 3
    }

    enum Outcome: Equatable {
        case answered(milliseconds: Int)
        case failed
    }

    /// The servers that answered, fastest first, and the ones that did not.
    static func summarize(_ results: [(server: String, outcome: Outcome)])
        -> (working: [(server: String, milliseconds: Int)], failed: [String]) {
        var working: [(server: String, milliseconds: Int)] = []
        var failed: [String] = []
        for result in results {
            if case .answered(let milliseconds) = result.outcome {
                working.append((result.server, milliseconds))
            } else {
                failed.append(result.server)
            }
        }
        return (working.sorted { $0.milliseconds < $1.milliseconds }, failed)
    }

    /// Whether a profile's DNS is usable. An IPv6 server may fail on an IPv4-only network, so one
    /// working server is enough; only when every server fails is the profile's DNS considered blocked.
    static func isBlocked(_ results: [(server: String, outcome: Outcome)]) -> Bool {
        !results.isEmpty && summarize(results).working.isEmpty
    }
}

/// Sends the probe over UDP with a deadline. Plain sockets, so it works for IPv4 and IPv6 alike.
enum DNSProbeClient {
    static func measure(server: String, name: String = "example.com", timeout: TimeInterval = 2) async -> DNSProbe.Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: measureBlocking(server: server, name: name, timeout: timeout))
            }
        }
    }

    static func measureAll(servers: [String], timeout: TimeInterval = 2) async -> [(server: String, outcome: DNSProbe.Outcome)] {
        await withTaskGroup(of: (Int, DNSProbe.Outcome).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask { (index, await measure(server: server, timeout: timeout)) }
            }
            var outcomes = [DNSProbe.Outcome](repeating: .failed, count: servers.count)
            for await (index, outcome) in group { outcomes[index] = outcome }
            return zip(servers, outcomes).map { ($0, $1) }
        }
    }

    private static func measureBlocking(server: String, name: String, timeout: TimeInterval) -> DNSProbe.Outcome {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST | AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, "53", &hints, &info) == 0, let address = info else { return .failed }
        defer { freeaddrinfo(info) }
        let descriptor = socket(address.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return .failed }
        defer { close(descriptor) }
        let id = UInt16.random(in: 1...UInt16.max)
        guard let packet = DNSProbe.query(name: name, id: id) else { return .failed }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let start = DispatchTime.now()
        let sent = packet.withUnsafeBytes { sendto(descriptor, $0.baseAddress, packet.count, 0, address.pointee.ai_addr, address.pointee.ai_addrlen) }
        guard sent == packet.count else { return .failed }
        var buffer = [UInt8](repeating: 0, count: 1500)
        let deadline = start.uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let received = recv(descriptor, &buffer, buffer.count, 0)
            if received < 0 { return .failed }
            if DNSProbe.isAnswer(Data(buffer.prefix(received)), id: id) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                return .answered(milliseconds: Int(elapsed / 1_000_000))
            }
        }
        return .failed
    }
}
