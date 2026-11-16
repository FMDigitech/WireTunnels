import Foundation

/// Measures round-trip latency to a host via the system ping(8) binary — the same
/// direct-shellout-from-the-app pattern NetworkMonitorService already uses for
/// networksetup(8). Plain ICMP echo needs no privilege escalation on macOS, so
/// this never touches the privileged helper.
enum PingService {
    // Immutable after construction and read only from the nonisolated function
    // below — safe to access from any isolation context despite the project's
    // MainActor-by-default setting.
    private nonisolated static let timeRegex = try? NSRegularExpression(pattern: #"time=([0-9.]+)\s*ms"#)

    /// Round-trip times in milliseconds for each reply received; empty if the
    /// host was unreachable or every request timed out. Blocking — call from a
    /// background task, not the main actor.
    nonisolated static func measureLatency(host: String, count: Int = 3, timeoutSeconds: Int = 2,
                                           boundInterface: String? = nil) -> [Double] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        var arguments = ["-c", String(count), "-t", String(timeoutSeconds)]
        // -b sends the probe out of one interface, so a monitor probe really crosses that tunnel.
        if let boundInterface { arguments += ["-b", boundInterface] }
        process.arguments = arguments + [host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let timeRegex else { return [] }

        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        return timeRegex.matches(in: output, range: fullRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: output) else { return nil }
            return Double(output[range])
        }
    }
}
