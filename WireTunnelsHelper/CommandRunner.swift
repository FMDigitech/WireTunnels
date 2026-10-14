import Darwin
import Foundation

/// Capture through pipes, but stop reading once the command exits. A daemon
/// inheriting stdout/stderr must not keep a completed setup command waiting for
/// pipe EOF. Output stays in memory because it can carry private keys.
struct CommandRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
        let timeoutStage: String?
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: String? = nil,
        timeout: TimeInterval = 25,
        terminationGrace: TimeInterval = 1,
        progress: ((String) -> Void)? = nil
    ) -> Result {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        for pipe in [stdoutPipe, stderrPipe] {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try process.run()
        } catch {
            try? stdinPipe?.fileHandleForWriting.close()
            return Result(stdout: "", stderr: error.localizedDescription, exitCode: -1, timedOut: false, timeoutStage: nil)
        }
        if let standardInput, let input = stdinPipe?.fileHandleForWriting {
            // Write off-thread so a command that never reads stdin still hits the deadline.
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? input.write(contentsOf: Data(standardInput.utf8))
                try? input.close()
            }
        }
        // Foundation gives launched tasks their own process group on macOS.
        // Verify that isolation before ever signalling a whole group.
        let processGroup = getpgid(process.processIdentifier)
        let isolatedGroup = processGroup == process.processIdentifier && processGroup != getpgrp()
        var stdoutData = Data()
        var stderrData = Data()
        var timedOut = false
        var timeoutStage: String?
        var progressOffset = 0
        var lastStage: String?
        func drain(_ pipe: Pipe, into data: inout Data) {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 { data.append(buffer, count: count) }
                else if count < 0 && errno == EINTR { continue }
                else { return }
            }
        }
        func collect() {
            drain(stdoutPipe, into: &stdoutData)
            drain(stderrPipe, into: &stderrData)
            guard let progress else { return }
            while let newline = stderrData[progressOffset...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: stderrData[progressOffset..<newline], as: UTF8.self)
                progressOffset = newline + 1
                if let stage = CommandProgress.stage(for: line), stage != lastStage {
                    progress(stage)
                    lastStage = stage
                }
            }
        }
        while process.isRunning {
            collect()
            if ProcessInfo.processInfo.systemUptime - started >= timeout {
                timedOut = true
                timeoutStage = lastStage
                progress?("command deadline exceeded; terminating setup")
                if isolatedGroup { _ = kill(-processGroup, SIGTERM) }
                else { process.terminate() }
                let graceDeadline = ProcessInfo.processInfo.systemUptime + terminationGrace
                while ProcessInfo.processInfo.systemUptime < graceDeadline {
                    collect()
                    let groupAlive = isolatedGroup && kill(-processGroup, 0) == 0
                    if !process.isRunning && !groupAlive { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if isolatedGroup { _ = kill(-processGroup, SIGKILL) }
                else if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        collect()
        return Result(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: timedOut ? 124 : process.terminationStatus,
            timedOut: timedOut,
            timeoutStage: timeoutStage
        )
    }
}

/// Only fixed stage names cross the logging boundary; command arguments and
/// configuration contents can contain addresses, keys, or user-specific names.
enum CommandProgress {
    static func stage(for line: String) -> String? {
        guard line.hasPrefix("[#]") || line.hasPrefix("[+]") else { return nil }
        if line.contains("wireguard-go") { return "creating userspace interface" }
        if line.contains("active network service(s) for DNS") { return "selecting active network services for DNS" }
        if line.contains("Active DNS service lookup unavailable") { return "active DNS selection unavailable; using configured services" }
        if line.contains("wg setconf") || line.contains("wg addconf") { return "applying peer configuration and resolving endpoint" }
        if line.contains("Restoring DNS after failed startup") { return "restoring DNS after failed startup" }
        if line.contains("Failed to restore DNS during startup cleanup") { return "DNS restoration failed" }
        if line.contains("ifconfig") { return "configuring interface" }
        if line.contains("networksetup -getdnsservers") { return "reading existing DNS" }
        if line.contains("networksetup -getsearchdomains") { return "reading existing search domains" }
        if line.contains("networksetup -setdnsservers") { return "updating system DNS" }
        if line.contains("networksetup -setsearchdomains") { return "updating search domains" }
        if line.contains("Backgrounding route monitor") { return "starting background route monitor" }
        if line.contains("route ") { return "configuring routes" }
        return nil
    }
}
