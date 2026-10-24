import Foundation

@main
struct TunnelConnectionReadinessTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var installed = WireGuardEnvironment()
        let paths = try ["wg", "wg-quick", "wireguard-go"].map { name in
            let url = root.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        installed.wgPath = paths[0]
        installed.wgQuickPath = paths[1]
        installed.wireguardGoPath = paths[2]
        installed.helperInstalled = true
        installed.binariesInstalled = true
        precondition(installed.isReady, "A fully installed, verified environment must be ready")

        for missingPath in [\WireGuardEnvironment.wgPath, \.wgQuickPath, \.wireguardGoPath] {
            var partial = installed
            partial[keyPath: missingPath] = nil
            precondition(!partial.isReady, "An environment missing any required tool must not connect")
        }

        var partial = installed
        partial.binariesInstalled = false
        precondition(!partial.isReady, "Paths alone must not bypass the helper's tool verification")
        partial = installed
        partial.helperInstalled = false
        precondition(!partial.isReady, "Connection requires the installed helper")

        for path in paths {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            precondition(!installed.isReady, "Non-executable tools must prevent connection")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        let ready = TunnelConnectionReadiness(
            environment: installed, isInitialized: true, isLoading: false,
            needsSetup: false, isShuttingDown: false
        )
        precondition(ready.canConnect && ready.unavailableReason == nil,
                     "Fully ready tools and app must allow connections without a warning")
        let blockedStates: [(String, WireGuardEnvironment, Bool, Bool, Bool, Bool)] = [
            ("initialization", installed, false, false, false, false),
            ("loading", installed, true, true, false, false),
            ("setup", installed, true, false, true, false),
            ("shutdown", installed, true, false, false, true),
            ("missing tools", WireGuardEnvironment(), true, false, false, false)
        ]
        for (name, environment, initialized, loading, setup, shutdown) in blockedStates {
            let readiness = TunnelConnectionReadiness(
                environment: environment, isInitialized: initialized, isLoading: loading,
                needsSetup: setup, isShuttingDown: shutdown
            )
            precondition(!readiness.canConnect, "Connection was allowed during \(name)")
            precondition(readiness.unavailableReason?.isEmpty == false,
                         "Blocked connection needs an explanation during \(name)")
        }

        try FileManager.default.removeItem(atPath: paths[2])
        precondition(!installed.isReady, "A removed tool must invalidate stale detected paths")
        print("PASS: connections require installed executable tools verified by the helper, and an app ready to connect")
    }
}
