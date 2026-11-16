import Foundation

@main
struct DNSProbeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() async {
        let query = DNSProbe.query(name: "example.com", id: 0x1234)!
        expect(Array(query.prefix(4)) == [0x12, 0x34, 0x01, 0x00], "the query must carry its id and ask for recursion")
        expect(Array(query.suffix(5)) == [0x00, 0x00, 0x01, 0x00, 0x01], "the query must end with root label, type A, class IN")
        expect(query.count == 12 + 1 + 7 + 1 + 3 + 1 + 4, "the name must be encoded as length-prefixed labels")
        expect(DNSProbe.query(name: "a..b", id: 1) == nil, "an empty label must be refused")
        expect(DNSProbe.query(name: String(repeating: "a", count: 64) + ".com", id: 1) == nil, "a label over 63 bytes must be refused")

        func reply(id: UInt16, flags: UInt8 = 0x81, code: UInt8 = 0) -> Data {
            Data([UInt8(id >> 8), UInt8(id & 0xFF), flags, 0x80 | code, 0, 1, 0, 0, 0, 0, 0, 0])
        }
        expect(DNSProbe.isAnswer(reply(id: 7), id: 7), "a matching reply must count")
        expect(!DNSProbe.isAnswer(reply(id: 8), id: 7), "a reply with another id must be ignored")
        expect(!DNSProbe.isAnswer(Data([0, 7, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0]), id: 7), "a query echoed back is not an answer")
        expect(DNSProbe.isAnswer(reply(id: 7, code: 3), id: 7), "NXDOMAIN still proves the server works")
        expect(!DNSProbe.isAnswer(reply(id: 7, code: 5), id: 7), "REFUSED must not count as working")
        expect(!DNSProbe.isAnswer(Data([1, 2, 3]), id: 7), "a truncated packet must be refused")

        let results: [(server: String, outcome: DNSProbe.Outcome)] = [
            ("9.9.9.9", .answered(milliseconds: 40)), ("2620:fe::fe", .failed), ("1.1.1.1", .answered(milliseconds: 12)),
        ]
        let summary = DNSProbe.summarize(results)
        expect(summary.working.map(\.server) == ["1.1.1.1", "9.9.9.9"], "working servers must be fastest first")
        expect(summary.failed == ["2620:fe::fe"], "failed servers must be listed")
        expect(!DNSProbe.isBlocked(results), "one working server is enough")
        expect(DNSProbe.isBlocked([("1.1.1.1", .failed), ("1.0.0.1", .failed)]), "all servers failing means the DNS is blocked")
        expect(!DNSProbe.isBlocked([]), "no servers is not a block")

        // The client always uses port 53, so only the failure paths can be checked without a network.
        let outcome = await DNSProbeClient.measure(server: "not an address", timeout: 0.2)
        expect(outcome == .failed, "a non-numeric server must fail without a lookup")
        let silent = await DNSProbeClient.measure(server: "127.0.0.1", timeout: 0.3)
        expect(silent == .failed, "a server that does not answer must fail after the timeout")
        print("DNSProbeTests passed")
    }
}
