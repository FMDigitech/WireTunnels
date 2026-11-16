import Foundation

@main
struct MeshVPNRunnerTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func script(_ directory: URL, _ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let json = try script(directory, "json", "echo '{\"BackendState\": \"Running\"}'")
        let result = MeshVPNRunner.run(json, ["status", "--json"], timeout: 5)
        check(result?.exitStatus == 0 && MeshVPNParser.parse(result?.output ?? Data(), kind: .tailscale)?.state == .running,
              "a client's output is read")

        // Arguments arrive one by one, exactly as given.
        let echo = try script(directory, "echo", "for a in \"$@\"; do echo \"[$a]\"; done")
        let echoed = MeshVPNRunner.run(echo, ["set", "--exit-node=100.64.0.2"], timeout: 5)
        check(String(data: echoed?.output ?? Data(), encoding: .utf8) == "[set]\n[--exit-node=100.64.0.2]\n", "arguments are passed unchanged")

        // Output far larger than a pipe buffer must not stall the tool.
        let big = try script(directory, "big", "head -c 1000000 /dev/zero | tr '\\0' 'a'")
        let large = MeshVPNRunner.run(big, [], timeout: 10)
        check(large?.output.count == 1_000_000, "a large output is read in full: \(large?.output.count ?? -1)")

        // A client that hangs is stopped.
        let hang = try script(directory, "hang", "sleep 30")
        let started = Date()
        check(MeshVPNRunner.run(hang, [], timeout: 1) == nil, "a client that does not finish is reported as nil")
        check(Date().timeIntervalSince(started) < 10, "and is stopped near the timeout, not left to run")

        // A failing client keeps its exit status and message.
        let failing = try script(directory, "fail", "echo 'failed to connect to local tailscaled'; exit 1")
        let failed = MeshVPNRunner.run(failing, [], timeout: 5)
        check(failed?.exitStatus == 1 && String(data: failed?.output ?? Data(), encoding: .utf8)?.contains("tailscaled") == true,
              "a failure keeps its status and message")
        check(MeshVPNParser.parse(failed?.output ?? Data(), kind: .tailscale) == nil, "a failure message is not a status")

        check(MeshVPNRunner.run(directory.appendingPathComponent("missing").path, [], timeout: 5) == nil, "a missing binary is nil")
        // Standard input is closed, so a client that waits for a keypress ends instead of hanging.
        let reader = try script(directory, "stdin", "read line; echo done")
        check(MeshVPNRunner.run(reader, [], timeout: 5)?.exitStatus != nil, "a client that reads stdin does not hang")
        print("PASS: mesh vpn runner")
    }
}
