import Foundation
import Darwin

@main
struct CommandRunnerTests {
    static func main() throws {
        let runner = CommandRunner()
        let start = ProcessInfo.processInfo.systemUptime
        let background = runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 2 & printf ready; printf done >&2"], timeout: 1)
        guard background.stdout == "ready", background.stderr == "done", background.exitCode == 0,
              !background.timedOut, ProcessInfo.processInfo.systemUptime - start < 1 else {
            fatalError("Exited setup command waited for background processes to close inherited output")
        }
        let echo = runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: "synthetic input\n")
        guard echo.stdout == "synthetic input\n", echo.exitCode == 0 else { fatalError("Command stdin was lost") }
        let unread = runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], standardInput: String(repeating: "x", count: 1 << 20), timeout: 2)
        guard unread.exitCode == 3, !unread.timedOut else { fatalError("Unread stdin blocked the command or raised SIGPIPE") }
        let large = runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null; dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null"], timeout: 2)
        guard large.stdout.utf8.count == 262144, large.stderr.utf8.count == 262144, large.exitCode == 0 else { fatalError("Large command output deadlocked or was truncated") }
        let hungStart = ProcessInfo.processInfo.systemUptime
        let hung = runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; printf before; sleep 10"], timeout: 0.15)
        guard hung.timedOut, hung.exitCode != 0, hung.stdout == "before",
              ProcessInfo.processInfo.systemUptime - hungStart < 2 else { fatalError("Hung foreground command was not bounded") }
        let descendant = runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 10 & printf '%s' $!; wait"], timeout: 0.15)
        guard let child = Int32(descendant.stdout) else { fatalError("Missing timeout fixture child PID") }
        let childStatus = Process()
        childStatus.executableURL = URL(fileURLWithPath: "/bin/ps")
        childStatus.arguments = ["-o", "stat=", "-p", String(child)]
        let statusOutput = Pipe()
        childStatus.standardOutput = statusOutput
        try childStatus.run()
        childStatus.waitUntilExit()
        let status = String(data: statusOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status.contains("Z") else {
            _ = kill(child, SIGKILL)
            fatalError("Timed-out setup left a descendant process running")
        }
        let failure = runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf failure >&2; exit 7"])
        guard failure.exitCode == 7, failure.stderr == "failure", !failure.timedOut else { fatalError("Command failure lost its exit code or diagnostic") }
        let absent = runner.run(executable: URL(fileURLWithPath: "/no/such/tool"), arguments: [])
        guard absent.exitCode == -1, !absent.stderr.isEmpty else { fatalError("Launch failure was hidden") }
        var stages: [String] = []
        let progress = runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '[#] wg setconf utun7 secret-file\\n' >&2; sleep 0.1; printf '[#] networksetup -setdnsservers secret-service secret-server\\n' >&2"], progress: { stages.append($0) })
        guard progress.exitCode == 0, stages == ["applying peer configuration and resolving endpoint", "updating system DNS"],
              CommandProgress.stage(for: "PrivateKey = synthetic-secret") == nil,
              CommandProgress.stage(for: "[#] wg addconf utun7 secret-file") == "applying peer configuration and resolving endpoint" else { fatalError("Progress diagnostics leaked arguments or lost the stalled stage") }
        print("PASS: command capture ignores inherited background descriptors and bounds hung setup")
    }
}
