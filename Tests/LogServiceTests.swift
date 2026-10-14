import Foundation

@main
struct LogServiceTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("diagnostics.log")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let log = LogService(logFile: file, defaults: defaults)
        let secret = Data(repeating: 1, count: 32).base64EncodedString()
        log.info("PrivateKey = \(secret)\nPresharedKey = invalid-synthetic-secret")
        log.error("Key is not the correct length or format: `malformed-synthetic-secret'")
        log.info("An opaque WireGuard key: \(secret)")
        let text = try String(contentsOf: file, encoding: .utf8)
        guard !text.contains(secret), !text.contains("invalid-synthetic-secret"), !text.contains("malformed-synthetic-secret"),
              text.contains("(hidden)") else { fatalError("Diagnostic logging leaked a WireGuard key") }
        let result: Int = await log.timed("synthetic staging") { 42 }
        guard result == 42, log.logLines.contains(where: { $0.contains("synthetic staging completed in") }) else { fatalError("Step timing hid the result or completion") }
        do {
            let _: Int = try await log.timed("synthetic failure") { throw NSError(domain: "test", code: 1) }
            fatalError("Timing swallowed an operation failure")
        } catch { }
        guard log.logLines.contains(where: { $0.contains("synthetic failure failed after") && $0.contains("[ERROR]") }) else { fatalError("Step failure timing was not logged") }
        print("PASS: diagnostics redact keys and record successful and failed step timings")
    }
}
